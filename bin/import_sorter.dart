// 🎯 Dart imports:
import 'dart:io';

// 📦 Package imports:
import 'package:args/args.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';

// 🌎 Project imports:
import 'package:import_sorter/args.dart' as local_args;
import 'package:import_sorter/sort.dart' as sort;

void main(List<String> args) {
  // Parsing arguments
  final parser = ArgParser();
  parser.addFlag('emojis', abbr: 'e', negatable: false);
  parser.addFlag('ignore-config', negatable: false);
  parser.addFlag('help', abbr: 'h', negatable: false);
  parser.addFlag('exit-if-changed', negatable: false);
  parser.addFlag('no-comments', negatable: false);
  final argResults = parser.parse(args).arguments;
  if (argResults.contains('-h') || argResults.contains('--help')) {
    local_args.outputHelp();
  }

  final currentPath = Directory.current.path;

  // Check if this is a workspace monorepo
  final workspacePackages = _getWorkspacePackages(currentPath);

  if (workspacePackages.isNotEmpty) {
    // Process each package in the workspace
    stdout.writeln('📦 Detected workspace with ${workspacePackages.length} packages\n');

    final globalStopwatch = Stopwatch();
    globalStopwatch.start();

    var totalSortedFiles = 0;

    // Get all workspace package names for import classification
    final workspacePackageNames = workspacePackages
        .map((path) => _getPackageName(path))
        .where((name) => name.isNotEmpty)
        .toList();

    // Read workspace root configuration
    final workspaceConfig = _getWorkspaceConfig(currentPath, argResults);

    for (final packagePath in workspacePackages) {
      final packageName = _getPackageName(packagePath);
      stdout.writeln('Processing package: $packageName ($packagePath)');

      final result = _processPackage(packagePath, args, argResults,
          workspacePackageNames: workspacePackageNames,
          workspaceConfig: workspaceConfig);
      totalSortedFiles += result;
      stdout.writeln('');
    }

    globalStopwatch.stop();

    final String totalTime = '${globalStopwatch.elapsed.inSeconds}.${globalStopwatch.elapsedMilliseconds.toString().padLeft(3, '0')}s';

    // Final summary with emphasis
    stdout.writeln('');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'WORKSPACE SUMMARY'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  📦 Packages processed: ${workspacePackages.length.toString().green().bold()}');
    stdout.writeln('  📝 Files sorted: ${totalSortedFiles.toString().green().bold()}');
    stdout.writeln('  ⏱️  Time elapsed: ${totalTime.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('');
    return;
  }

  // Standard single package processing
  _processPackage(currentPath, args, argResults);
}

/// Process a single package (works for both standalone projects and workspace packages)
int _processPackage(
    String packagePath,
    List<String> args,
    List<String> argResults, {
    List<String> workspacePackageNames = const [],
    Map<String, dynamic>? workspaceConfig,
  }) {
  /*
  Getting the package name and dependencies/dev_dependencies
  Package name is one factor used to identify project imports
  Dependencies/dev_dependencies names are used to identify package imports
  */
  final pubspecYamlFile = File('$packagePath/pubspec.yaml');
  if (!pubspecYamlFile.existsSync()) {
    stdout.writeln('⚠️  Skipping $packagePath - no pubspec.yaml found');
    return 0;
  }

  final pubspecYaml = loadYaml(pubspecYamlFile.readAsStringSync());

  // Getting all dependencies and project package name
  final packageName = pubspecYaml['name'];
  final dependencies = [];

  final stopwatch = Stopwatch();
  stopwatch.start();

  final pubspecLockFile = File('$packagePath/pubspec.lock');
  if (pubspecLockFile.existsSync()) {
    final pubspecLock = loadYaml(pubspecLockFile.readAsStringSync());
    dependencies.addAll(pubspecLock['packages'].keys);
  }

  var emojis = false;
  var noComments = false;
  final ignoredFiles = [];

  // Reading from config in pubspec.yaml safely
  if (!argResults.contains('--ignore-config')) {
    // First, apply workspace root configuration (if provided)
    if (workspaceConfig != null) {
      if (workspaceConfig.containsKey('emojis')) emojis = workspaceConfig['emojis'];
      if (workspaceConfig.containsKey('comments')) noComments = !workspaceConfig['comments'];
      if (workspaceConfig.containsKey('ignored_files')) {
        ignoredFiles.addAll(workspaceConfig['ignored_files']);
      }
    }

    // Then, allow package-level override
    if (pubspecYaml.containsKey('import_sorter')) {
      final config = pubspecYaml['import_sorter'];
      if (config.containsKey('emojis')) emojis = config['emojis'];
      if (config.containsKey('comments')) noComments = !config['comments'];
      if (config.containsKey('ignored_files')) {
        ignoredFiles.clear();
        ignoredFiles.addAll(config['ignored_files']);
      }
    }
  }

  // Setting values from args
  if (!emojis) emojis = argResults.contains('-e');
  if (!noComments) noComments = argResults.contains('--no-comments');
  final exitOnChange = argResults.contains('--exit-if-changed');

  // Getting all the dart files for the project/package
  final dartFiles = _getSinglePackageDartFiles(packagePath, args);
  final containsFlutter = dependencies.contains('flutter');
  final containsRegistrant = dartFiles
      .containsKey('$packagePath/lib/generated_plugin_registrant.dart');

  stdout.writeln('contains flutter: $containsFlutter');
  stdout.writeln('contains registrant: $containsRegistrant');

  if (containsFlutter && containsRegistrant) {
    dartFiles.remove('$packagePath/lib/generated_plugin_registrant.dart');
  }

  for (final pattern in ignoredFiles) {
    dartFiles.removeWhere((key, _) =>
        RegExp(pattern).hasMatch(key.replaceFirst(packagePath, '')));
  }

  stdout.write('┏━━ Sorting ${dartFiles.length} dart files');

  // Sorting and writing to files
  final sortedFiles = [];
  final success = '✔'.green();

  for (final filePath in dartFiles.keys) {
    final file = dartFiles[filePath];
    if (file == null) {
      continue;
    }

    final sortedFile = sort.sortImports(
        file.readAsLinesSync(),
        packageName,
        emojis,
        exitOnChange,
        noComments,
        workspacePackages: workspacePackageNames,
    );
    if (!sortedFile.updated) {
      continue;
    }
    dartFiles[filePath]?.writeAsStringSync(sortedFile.sortedFile);
    sortedFiles.add(filePath);
  }

  stopwatch.stop();

  // Outputting results
  if (sortedFiles.length > 1) {
    stdout.write('\n');
  }
  for (int i = 0; i < sortedFiles.length; i++) {
    final file = dartFiles[sortedFiles[i]];
    stdout.write(
        '${sortedFiles.length == 1 ? '\n' : ''}┃  ${i == sortedFiles.length - 1 ? '┗' : '┣'}━━ $success Sorted imports for ${file?.path.replaceFirst(packagePath, '')}/');
    String filename = file!.path.split(Platform.pathSeparator).last;
    stdout.write('$filename\n');
  }

  if (sortedFiles.isEmpty) {
    stdout.write('\n');
  }
  stdout.write(
      '┗━━ $success Sorted ${sortedFiles.length} files in ${stopwatch.elapsed.inSeconds}.${stopwatch.elapsedMilliseconds} seconds\n');

  // Don't show final summary if in workspace mode (summary is shown at workspace level)
  if (workspacePackageNames.isEmpty) {
    final String totalTime = '${stopwatch.elapsed.inSeconds}.${stopwatch.elapsedMilliseconds.toString().padLeft(3, '0')}s';

    // Final summary with emphasis for single package
    stdout.writeln('');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'SUMMARY'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  📝 Files sorted: ${sortedFiles.length.toString().green().bold()}');
    stdout.writeln('  ⏱️  Time elapsed: ${totalTime.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('');
  }

  return sortedFiles.length;
}

/// Get workspace root configuration from pubspec.yaml
Map<String, dynamic>? _getWorkspaceConfig(String currentPath, List<String> argResults) {
  // If --ignore-config is set, don't read any config
  if (argResults.contains('--ignore-config')) {
    return null;
  }

  try {
    final pubspecFile = File('$currentPath/pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      return null;
    }

    final pubspecContent = pubspecFile.readAsStringSync();
    final pubspecYaml = loadYaml(pubspecContent);

    if (pubspecYaml is Map && pubspecYaml.containsKey('import_sorter')) {
      final config = pubspecYaml['import_sorter'];
      if (config is Map) {
        return Map<String, dynamic>.from(config);
      }
    }
  } catch (e) {
    // If there's any error reading config, return null
    return null;
  }

  return null;
}

/// Get all workspace package paths if this is a monorepo with workspace configuration
List<String> _getWorkspacePackages(String currentPath) {
  final packages = <String>[];

  try {
    final pubspecFile = File('$currentPath/pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      return packages;
    }

    final pubspecContent = pubspecFile.readAsStringSync();
    final pubspecYaml = loadYaml(pubspecContent);

    // Check if workspace is defined
    if (pubspecYaml is! Map || !pubspecYaml.containsKey('workspace')) {
      return packages;
    }

    final workspace = pubspecYaml['workspace'];
    if (workspace == null) {
      return packages;
    }

    // Get the list of packages from workspace
    List<String> workspacePatterns = [];
    if (workspace is List) {
      workspacePatterns = workspace.map((e) => e.toString()).toList();
    } else if (workspace is Map && workspace.containsKey('packages')) {
      final packagesValue = workspace['packages'];
      if (packagesValue is List) {
        workspacePatterns = packagesValue.map((e) => e.toString()).toList();
      }
    }

    // Resolve each pattern to actual directories
    for (final pattern in workspacePatterns) {
      final resolvedPaths = _resolveWorkspacePattern(currentPath, pattern);
      packages.addAll(resolvedPaths);
    }
  } catch (e) {
    // If there's any error reading workspace config, return empty list
    return [];
  }

  return packages;
}

/// Resolve a workspace pattern to actual directory paths
List<String> _resolveWorkspacePattern(String basePath, String pattern) {
  final paths = <String>[];

  // Remove trailing slash if present
  final cleanPattern = pattern.endsWith('/')
      ? pattern.substring(0, pattern.length - 1)
      : pattern;

  // Handle glob patterns like packages/* or apps/*
  if (cleanPattern.contains('*')) {
    final parts = cleanPattern.split('/');
    var currentPath = basePath;

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];

      if (part == '*') {
        // List all directories at current level
        final dir = Directory(currentPath);
        if (dir.existsSync()) {
          final entries = dir.listSync(followLinks: false);
          for (final entry in entries) {
            if (entry is Directory) {
              if (i == parts.length - 1) {
                // This is the last part, check if it has pubspec.yaml
                final pubspecPath = '${entry.path}/pubspec.yaml';
                if (File(pubspecPath).existsSync()) {
                  paths.add(entry.path);
                }
              } else {
                // Continue with remaining parts
                final remaining = parts.sublist(i + 1).join('/');
                paths.addAll(_resolveWorkspacePattern(entry.path, remaining));
              }
            }
          }
        }
        break; // Stop processing after wildcard
      } else {
        currentPath = '$currentPath/$part';
      }
    }
  } else {
    // Direct path without wildcards
    final fullPath = '$basePath/$cleanPattern';
    final dir = Directory(fullPath);
    if (dir.existsSync() && File('$fullPath/pubspec.yaml').existsSync()) {
      paths.add(fullPath);
    }
  }

  return paths;
}

/// Get the package name from a pubspec.yaml file
String _getPackageName(String packagePath) {
  try {
    final pubspecFile = File('$packagePath/pubspec.yaml');
    if (pubspecFile.existsSync()) {
      final pubspecYaml = loadYaml(pubspecFile.readAsStringSync());
      if (pubspecYaml is Map && pubspecYaml.containsKey('name')) {
        return pubspecYaml['name'].toString();
      }
    }
  } catch (e) {
    // Ignore errors
  }
  return packagePath.split(Platform.pathSeparator).last;
}

/// Get all dart files for a single package (not using workspace logic)
Map<String, File> _getSinglePackageDartFiles(String packagePath, List<String> args) {
  final dartFiles = <String, File>{};
  final allContents = [
    ..._readDirLocal(packagePath, 'lib'),
    ..._readDirLocal(packagePath, 'bin'),
    ..._readDirLocal(packagePath, 'test'),
    ..._readDirLocal(packagePath, 'tests'),
    ..._readDirLocal(packagePath, 'test_driver'),
    ..._readDirLocal(packagePath, 'integration_test'),
  ];

  for (final fileOrDir in allContents) {
    if (fileOrDir is File && fileOrDir.path.endsWith('.dart')) {
      dartFiles[fileOrDir.path] = fileOrDir;
    }
  }

  // If there are only certain files given via args filter the others out
  var onlyCertainFiles = false;
  for (final arg in args) {
    if (!onlyCertainFiles) {
      onlyCertainFiles = arg.endsWith('dart');
    }
  }

  if (onlyCertainFiles) {
    final patterns = args.where((arg) => !arg.startsWith('-'));
    final filesToKeep = <String, File>{};

    for (final fileName in dartFiles.keys) {
      var keep = false;
      for (final pattern in patterns) {
        if (RegExp(pattern).hasMatch(fileName)) {
          keep = true;
          break;
        }
      }
      if (keep) {
        filesToKeep[fileName] = File(fileName);
      }
    }
    return filesToKeep;
  }

  return dartFiles;
}

List<FileSystemEntity> _readDirLocal(String currentPath, String name) {
  if (Directory('$currentPath/$name').existsSync()) {
    return Directory('$currentPath/$name').listSync(recursive: true);
  }
  return [];
}
