// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:args/args.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/process.dart';
import '../cache.dart';
import '../dart/analysis.dart';
import '../globals.dart';
import 'analyze.dart';
import 'analyze_base.dart';

bool isDartFile(FileSystemEntity entry) => entry is File && entry.path.endsWith('.dart');

typedef bool FileFilter(FileSystemEntity entity);

/// An aspect of the [AnalyzeCommand] to perform once time analysis.
class AnalyzeOnce extends AnalyzeBase {
  final List<Directory> repoPackages;

  AnalyzeOnce(ArgResults argResults, this.repoPackages) : super(argResults);

  @override
  Future<Null> analyze() async {
    final Stopwatch stopwatch = new Stopwatch()..start();
    final Set<Directory> pubSpecDirectories = new HashSet<Directory>();
    final List<File> dartFiles = <File>[];

    for (String file in argResults.rest.toList()) {
      file = fs.path.normalize(fs.path.absolute(file));
      final String root = fs.path.rootPrefix(file);
      dartFiles.add(fs.file(file));
      while (file != root) {
        file = fs.path.dirname(file);
        if (fs.isFileSync(fs.path.join(file, 'pubspec.yaml'))) {
          pubSpecDirectories.add(fs.directory(file));
          break;
        }
      }
    }

    final bool currentPackage = argResults['current-package'] && (argResults.wasParsed('current-package') || dartFiles.isEmpty);
    final bool flutterRepo = argResults['flutter-repo'] || inRepo(argResults.rest);

    // Use dartanalyzer directly except when analyzing the Flutter repository.
    // Analyzing the repository requires a more complex report than dartanalyzer
    // currently supports (e.g. missing member dartdoc summary).
    // TODO(danrubel) enhance dartanalyzer to provide this type of summary
    if (!flutterRepo) {
      final List<String> arguments = <String>[];
      arguments.addAll(dartFiles.map((FileSystemEntity f) => f.path));

      if (arguments.length < 1 || currentPackage) {
        final Directory projectDirectory = await projectDirectoryContaining(fs.currentDirectory.absolute);
        if (projectDirectory != null)
          arguments.add(projectDirectory.path);
      } else {
        String currentDirectoryPath = fs.currentDirectory.path;
        if (!currentDirectoryPath.endsWith(fs.path.separator))
          currentDirectoryPath += fs.path.separator;

        // If the files being analyzed are outside of the current directory hierarchy
        // then dartanalyzer does not yet know how to find the ".packages" file.
        // In this situation, use the first file as a starting point
        // to search for a "pubspec.yaml" and ".packages" file.
        // TODO(danrubel): fix dartanalyzer to find the .packages file
        if (!arguments[0].startsWith(currentDirectoryPath)) {
          final String targetPath = arguments[0];
          final FileSystemEntity target = await fs.isDirectory(targetPath)
              ? fs.directory(targetPath) : fs.file(targetPath);
          final Directory projDir = await projectDirectoryContaining(target);
          if (projDir != null) {
            final String packagesPath = fs.path.join(projDir.path, '.packages');
            if (packagesPath != null) {
              arguments.insert(0, '--packages');
              arguments.insert(1, packagesPath);
            }
          }
        }
      }

      final String dartanalyzer = fs.path.join(Cache.flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dartanalyzer');
      arguments.insert(0, dartanalyzer);
      final int exitCode = await runCommandAndStreamOutput(arguments);
      stopwatch.stop();
      final String elapsed = (stopwatch.elapsedMilliseconds / 1000.0).toStringAsFixed(1);
      if (exitCode != 0)
        throwToolExit('(Ran in ${elapsed}s)', exitCode: exitCode);
      printStatus('Ran in ${elapsed}s');
      return;
    }

    //TODO (pq): revisit package and directory defaults

    for (Directory dir in repoPackages) {
      _collectDartFiles(dir, dartFiles);
      pubSpecDirectories.add(dir);
    }

    // determine what all the various .packages files depend on
    final PackageDependencyTracker dependencies = new PackageDependencyTracker();
    for (Directory directory in pubSpecDirectories) {
      final String pubSpecYamlPath = fs.path.join(directory.path, 'pubspec.yaml');
      final File pubSpecYamlFile = fs.file(pubSpecYamlPath);
      if (pubSpecYamlFile.existsSync()) {
        // we are analyzing the actual canonical source for this package;
        // make sure we remember that, in case all the packages are actually
        // pointing elsewhere somehow.
        final yaml.YamlMap pubSpecYaml = yaml.loadYaml(fs.file(pubSpecYamlPath).readAsStringSync());
        final String packageName = pubSpecYaml['name'];
        final String packagePath = fs.path.normalize(fs.path.absolute(fs.path.join(directory.path, 'lib')));
        dependencies.addCanonicalCase(packageName, packagePath, pubSpecYamlPath);
      }
      final String dotPackagesPath = fs.path.join(directory.path, '.packages');
      final File dotPackages = fs.file(dotPackagesPath);
      if (dotPackages.existsSync()) {
        // this directory has opinions about what we should be using
        dotPackages
          .readAsStringSync()
          .split('\n')
          .where((String line) => !line.startsWith(new RegExp(r'^ *#')))
          .forEach((String line) {
            final int colon = line.indexOf(':');
            if (colon > 0) {
              final String packageName = line.substring(0, colon);
              final String packagePath = fs.path.fromUri(line.substring(colon+1));
              // Ensure that we only add the `analyzer` package defined in the vended SDK (and referred to with a local fs.path. directive).
              // Analyzer package versions reached via transitive dependencies (e.g., via `test`) are ignored since they would produce
              // spurious conflicts.
              if (packageName != 'analyzer' || packagePath.startsWith('..'))
                dependencies.add(packageName, fs.path.normalize(fs.path.absolute(directory.path, packagePath)), dotPackagesPath);
            }
        });
      }
    }

    // prepare a union of all the .packages files
    if (dependencies.hasConflicts) {
      final StringBuffer message = new StringBuffer();
      message.writeln(dependencies.generateConflictReport());
      message.writeln('Make sure you have run "pub upgrade" in all the directories mentioned above.');
      if (dependencies.hasConflictsAffectingFlutterRepo) {
        message.writeln(
            'For packages in the flutter repository, try using '
            '"flutter update-packages --upgrade" to do all of them at once.');
      }
      message.write(
          'If this does not help, to track down the conflict you can use '
          '"pub deps --style=list" and "pub upgrade --verbosity=solver" in the affected directories.');
      throwToolExit(message.toString());
    }
    final Map<String, String> packages = dependencies.asPackageMap();

    Cache.releaseLockEarly();

    if (argResults['preamble']) {
      if (dartFiles.length == 1) {
        logger.printStatus('Analyzing ${fs.path.relative(dartFiles.first.path)}...');
      } else {
        logger.printStatus('Analyzing ${dartFiles.length} files...');
      }
    }
    final DriverOptions options = new DriverOptions();
    options.dartSdkPath = argResults['dart-sdk'];
    options.packageMap = packages;
    options.analysisOptionsFile = fs.path.join(Cache.flutterRoot, '.analysis_options_repo');
    final AnalysisDriver analyzer = new AnalysisDriver(options);

    // TODO(pq): consider error handling
    final List<AnalysisErrorDescription> errors = analyzer.analyze(dartFiles);

    int errorCount = 0;
    int membersMissingDocumentation = 0;
    for (AnalysisErrorDescription error in errors) {
      bool shouldIgnore = false;
      if (error.errorCode.name == 'public_member_api_docs') {
        // https://github.com/dart-lang/linter/issues/208
        if (isFlutterLibrary(error.source.fullName)) {
          if (!argResults['dartdocs']) {
            membersMissingDocumentation += 1;
            shouldIgnore = true;
          }
        } else {
          shouldIgnore = true;
        }
      }
      if (shouldIgnore)
        continue;
      printError(error.asString());
      errorCount += 1;
    }
    dumpErrors(errors.map<String>((AnalysisErrorDescription error) => error.asString()));

    stopwatch.stop();
    final String elapsed = (stopwatch.elapsedMilliseconds / 1000.0).toStringAsFixed(1);

    if (isBenchmarking)
      writeBenchmark(stopwatch, errorCount, membersMissingDocumentation);

    if (errorCount > 0) {
      // we consider any level of error to be an error exit (we don't report different levels)
      if (membersMissingDocumentation > 0)
        throwToolExit('[lint] $membersMissingDocumentation public ${ membersMissingDocumentation == 1 ? "member lacks" : "members lack" } documentation (ran in ${elapsed}s)');
      else
        throwToolExit('(Ran in ${elapsed}s)');
    }
    if (argResults['congratulate']) {
      if (membersMissingDocumentation > 0) {
        printStatus('No analyzer warnings! (ran in ${elapsed}s; $membersMissingDocumentation public ${ membersMissingDocumentation == 1 ? "member lacks" : "members lack" } documentation)');
      } else {
        printStatus('No analyzer warnings! (ran in ${elapsed}s)');
      }
    }
  }

  Future<Directory> projectDirectoryContaining(FileSystemEntity entity) async {
    Directory dir = entity is Directory ? entity : entity.parent;
    dir = dir.absolute;
    while (!await dir.childFile('pubspec.yaml').exists()) {
      final Directory parent = dir.parent;
      if (parent == null || parent.path == dir.path)
        return null;
      dir = parent;
    }
    return dir;
  }

  List<String> flutterRootComponents;
  bool isFlutterLibrary(String filename) {
    flutterRootComponents ??= fs.path.normalize(fs.path.absolute(Cache.flutterRoot)).split(fs.path.separator);
    final List<String> filenameComponents = fs.path.normalize(fs.path.absolute(filename)).split(fs.path.separator);
    if (filenameComponents.length < flutterRootComponents.length + 4) // the 4: 'packages', package_name, 'lib', file_name
      return false;
    for (int index = 0; index < flutterRootComponents.length; index += 1) {
      if (flutterRootComponents[index] != filenameComponents[index])
        return false;
    }
    if (filenameComponents[flutterRootComponents.length] != 'packages')
      return false;
    if (filenameComponents[flutterRootComponents.length + 1] == 'flutter_tools')
      return false;
    if (filenameComponents[flutterRootComponents.length + 2] != 'lib')
      return false;
    return true;
  }

  List<File> _collectDartFiles(Directory dir, List<File> collected) {
    // Bail out in case of a .dartignore.
    if (fs.isFileSync(fs.path.join(dir.path, '.dartignore')))
      return collected;

    for (FileSystemEntity entity in dir.listSync(recursive: false, followLinks: false)) {
      if (isDartFile(entity))
        collected.add(entity);
      if (entity is Directory) {
        final String name = fs.path.basename(entity.path);
        if (!name.startsWith('.') && name != 'packages')
          _collectDartFiles(entity, collected);
      }
    }

    return collected;
  }
}

class PackageDependency {
  // This is a map from dependency targets (lib directories) to a list
  // of places that ask for that target (.packages or pubspec.yaml files)
  Map<String, List<String>> values = <String, List<String>>{};
  String canonicalSource;
  void addCanonicalCase(String packagePath, String pubSpecYamlPath) {
    assert(canonicalSource == null);
    add(packagePath, pubSpecYamlPath);
    canonicalSource = pubSpecYamlPath;
  }
  void add(String packagePath, String sourcePath) {
    values.putIfAbsent(packagePath, () => <String>[]).add(sourcePath);
  }
  bool get hasConflict => values.length > 1;
  bool get hasConflictAffectingFlutterRepo {
    assert(fs.path.isAbsolute(Cache.flutterRoot));
    for (List<String> targetSources in values.values) {
      for (String source in targetSources) {
        assert(fs.path.isAbsolute(source));
        if (fs.path.isWithin(Cache.flutterRoot, source))
          return true;
      }
    }
    return false;
  }
  void describeConflict(StringBuffer result) {
    assert(hasConflict);
    final List<String> targets = values.keys.toList();
    targets.sort((String a, String b) => values[b].length.compareTo(values[a].length));
    for (String target in targets) {
      final int count = values[target].length;
      result.writeln('  $count ${count == 1 ? 'source wants' : 'sources want'} "$target":');
      bool canonical = false;
      for (String source in values[target]) {
        result.writeln('    $source');
        if (source == canonicalSource)
          canonical = true;
      }
      if (canonical) {
        result.writeln('    (This is the actual package definition, so it is considered the canonical "right answer".)');
      }
    }
  }
  String get target => values.keys.single;
}

class PackageDependencyTracker {
  // This is a map from package names to objects that track the paths
  // involved (sources and targets).
  Map<String, PackageDependency> packages = <String, PackageDependency>{};

  PackageDependency getPackageDependency(String packageName) {
    return packages.putIfAbsent(packageName, () => new PackageDependency());
  }

  void addCanonicalCase(String packageName, String packagePath, String pubSpecYamlPath) {
    getPackageDependency(packageName).addCanonicalCase(packagePath, pubSpecYamlPath);
  }

  void add(String packageName, String packagePath, String dotPackagesPath) {
    getPackageDependency(packageName).add(packagePath, dotPackagesPath);
  }

  bool get hasConflicts {
    return packages.values.any((PackageDependency dependency) => dependency.hasConflict);
  }

  bool get hasConflictsAffectingFlutterRepo {
    return packages.values.any((PackageDependency dependency) => dependency.hasConflictAffectingFlutterRepo);
  }

  String generateConflictReport() {
    assert(hasConflicts);
    final StringBuffer result = new StringBuffer();
    for (String package in packages.keys.where((String package) => packages[package].hasConflict)) {
      result.writeln('Package "$package" has conflicts:');
      packages[package].describeConflict(result);
    }
    return result.toString();
  }

  Map<String, String> asPackageMap() {
    final Map<String, String> result = <String, String>{};
    for (String package in packages.keys)
      result[package] = packages[package].target;
    return result;
  }
}
