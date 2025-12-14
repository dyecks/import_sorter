// 🎯 Dart imports:
import 'dart:io';

// 📦 Package imports:
import 'package:args/args.dart';
import 'package:tint/tint.dart';
import 'package:yaml/yaml.dart';

// 🌎 Project imports:
import 'package:import_sorter/args.dart' as local_args;
import 'package:import_sorter/sort.dart' as sort;

/// Result class to hold processing results
class ProcessResult {
  final int sortedCount;
  final List<String> ignoredFiles;

  ProcessResult(this.sortedCount, this.ignoredFiles);
}

/// Patterns for generated files that should be ignored
final List<String> _generatedFilePatterns = [
  r'\.g\.dart$',
  r'\.freezed\.dart$',
  r'\.gr\.dart$',
  r'\.gen\.dart$',
  r'\.mocks\.dart$',
  r'\.config\.dart$',
  r'\.chopper\.dart$',
  r'\.reflectable\.dart$',
];

void main(List<String> args) {
  // Parsing arguments
  final parser = ArgParser();
  parser.addFlag('emojis', abbr: 'e', negatable: false);
  parser.addFlag('ignore-config', negatable: false);
  parser.addFlag('help', abbr: 'h', negatable: false);
  parser.addFlag('exit-if-changed', negatable: false);
  parser.addFlag('no-comments', negatable: false);
  parser.addFlag('list-ignored', abbr: 'l', negatable: false);
  final argResults = parser.parse(args).arguments;
  if (argResults.contains('-h') || argResults.contains('--help')) {
    local_args.outputHelp();
  }

  final listIgnored = argResults.contains('-l') || argResults.contains('--list-ignored');

  final currentPath = Directory.current.path;

  // Check if this is a workspace monorepo
  final workspacePackages = _getWorkspacePackages(currentPath);

  if (workspacePackages.isNotEmpty) {
    // Process each package in the workspace
    stdout.writeln('');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'Workspace with ${workspacePackages.length} packages'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());

    final globalStopwatch = Stopwatch();
    globalStopwatch.start();

    var totalSortedFiles = 0;
    final allIgnoredFiles = <String>[];

    // Get all workspace package names for import classification
    final workspacePackageNames = workspacePackages
        .map((path) => _getPackageName(path))
        .where((name) => name.isNotEmpty)
        .toList();

    // Read workspace root configuration
    final workspaceConfig = _getWorkspaceConfig(currentPath, argResults);

    for (final packagePath in workspacePackages) {
      final result = _processPackage(packagePath, args, argResults,
          workspacePackageNames: workspacePackageNames,
          workspaceConfig: workspaceConfig,
          listIgnored: listIgnored);
      totalSortedFiles += result.sortedCount;
      allIgnoredFiles.addAll(result.ignoredFiles);
    }

    globalStopwatch.stop();

    final String totalTime = '${globalStopwatch.elapsed.inSeconds}.${globalStopwatch.elapsedMilliseconds.toString().padLeft(3, '0')}s';

    // Final summary with emphasis
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'Workspace Summary'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  📦 Packages processed: ${workspacePackages.length.toString().green().bold()}');
    stdout.writeln('  📝 Files sorted: ${totalSortedFiles.toString().green().bold()}');
    stdout.writeln('  🚫 Files ignored: ${allIgnoredFiles.length.toString().green().bold()}');
    stdout.writeln('  ⏱️  Time elapsed: ${totalTime.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());

    // List ignored files if requested
    if (listIgnored && allIgnoredFiles.isNotEmpty) {
      stdout.writeln('  📋 ${'Ignored files:'.yellow()}');
      for (final file in allIgnoredFiles) {
        var displayPath = file.replaceFirst(currentPath, '');
        if (displayPath.startsWith('/') || displayPath.startsWith('\\')) {
          displayPath = displayPath.substring(1);
        }
        // Normalize to forward slashes for consistent display
        displayPath = displayPath.replaceAll('\\', '/');
        stdout.writeln('     ❌ $displayPath');
      }
    }

    stdout.writeln('');
    return;
  }

  // Standard single package processing
  _processPackage(currentPath, args, argResults, listIgnored: listIgnored);
}

/// Process a single package (works for both standalone projects and workspace packages)
ProcessResult _processPackage(
    String packagePath,
    List<String> args,
    List<String> argResults, {
    List<String> workspacePackageNames = const [],
    Map<String, dynamic>? workspaceConfig,
    bool listIgnored = false,
  }) {
  /*
  Getting the package name and dependencies/dev_dependencies
  Package name is one factor used to identify project imports
  Dependencies/dev_dependencies names are used to identify package imports
  */
  final pubspecYamlFile = File('$packagePath/pubspec.yaml');
  if (!pubspecYamlFile.existsSync()) {
    stdout.writeln('⚠️  Skipping $packagePath - no pubspec.yaml found');
    return ProcessResult(0, []);
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

  // Track ignored files (using Set to avoid duplicates)
  final ignoredFilesSet = <String>{};

  // Check generated_plugin_registrant.dart
  if (containsFlutter && containsRegistrant) {
    ignoredFilesSet.add('$packagePath/lib/generated_plugin_registrant.dart');
  }

  // Load .gitignore patterns
  final gitignorePatterns = _loadGitignorePatterns(packagePath);

  // Check all dart files against all ignore criteria
  for (final filePath in dartFiles.keys.toList()) {
    var shouldIgnore = false;

    // Check if already marked as ignored (registrant)
    if (ignoredFilesSet.contains(filePath)) {
      shouldIgnore = true;
    }

    // Check .gitignore patterns
    if (!shouldIgnore) {
      // Normalize path to use / for gitignore matching
      var relativePath = filePath.replaceFirst(packagePath, '');
      if (Platform.isWindows) {
        relativePath = relativePath.replaceAll(r'\', '/');
      }
      // Remove leading slash if present
      if (relativePath.startsWith('/')) {
        relativePath = relativePath.substring(1);
      }

      for (final pattern in gitignorePatterns) {
        if (_matchesGitignorePattern(relativePath, pattern)) {
          shouldIgnore = true;
          break;
        }
      }
    }

    // Check generated files patterns
    if (!shouldIgnore) {
      for (final pattern in _generatedFilePatterns) {
        if (RegExp(pattern).hasMatch(filePath)) {
          shouldIgnore = true;
          break;
        }
      }
    }

    // Check custom ignored patterns from config
    if (!shouldIgnore) {
      for (final pattern in ignoredFiles) {
        if (RegExp(pattern).hasMatch(filePath.replaceFirst(packagePath, ''))) {
          shouldIgnore = true;
          break;
        }
      }
    }

    // Add to ignored set if should be ignored
    if (shouldIgnore) {
      ignoredFilesSet.add(filePath);
    }
  }

  // Remove all ignored files from dartFiles
  for (final ignoredFile in ignoredFilesSet) {
    dartFiles.remove(ignoredFile);
  }

  // Convert set to list for display
  final ignoredFilesList = ignoredFilesSet.toList();

  // Display package info in a single line (only for workspace packages)
  if (workspacePackageNames.isNotEmpty) {
    final flutterIcon = containsFlutter ? '🐦' : '  ';
    final registrantIcon = containsRegistrant ? '📄' : '  ';
    stdout.writeln('  📦 $packageName  $flutterIcon $registrantIcon');
  }

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
  if (workspacePackageNames.isNotEmpty) {
    // Workspace mode: compact output
    if (sortedFiles.isEmpty) {
      stdout.writeln('     ${'No files sorted'.gray()}');
    } else {
      for (int i = 0; i < sortedFiles.length; i++) {
        final file = dartFiles[sortedFiles[i]];
        final relativePath = file?.path.replaceFirst(packagePath, '') ?? '';
        stdout.writeln('     $success ${relativePath.replaceFirst('/', '')}');
      }
    }
    stdout.writeln('');
  } else {
    // Single package mode: similar to workspace output
    stdout.writeln('');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'Single Package'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());

    final flutterIcon = containsFlutter ? '🐦' : '  ';
    final registrantIcon = containsRegistrant ? '📄' : '  ';
    stdout.writeln('  📦 $packageName  $flutterIcon $registrantIcon');

    if (sortedFiles.isEmpty) {
      stdout.writeln('     ${'No files sorted'.gray()}');
    } else {
      for (int i = 0; i < sortedFiles.length; i++) {
        final file = dartFiles[sortedFiles[i]];
        final relativePath = file?.path.replaceFirst(packagePath, '') ?? '';
        stdout.writeln('     $success ${relativePath.replaceFirst('/', '')}');
      }
    }
    stdout.writeln('');

    final String totalTime = '${stopwatch.elapsed.inSeconds}.${stopwatch.elapsedMilliseconds.toString().padLeft(3, '0')}s';

    // Final summary with emphasis for single package
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  ✨ ${'SUMMARY'.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());
    stdout.writeln('  📝 Files sorted: ${sortedFiles.length.toString().green().bold()}');
    stdout.writeln('  🚫 Files ignored: ${ignoredFilesList.length.toString().green().bold()}');
    stdout.writeln('  ⏱️  Time elapsed: ${totalTime.green().bold()}');
    stdout.writeln('═══════════════════════════════════════════════════════════'.gray());

    // List ignored files if requested
    if (listIgnored && ignoredFilesList.isNotEmpty) {
      stdout.writeln('  📋 ${'Ignored files:'.yellow()}');
      for (final file in ignoredFilesList) {
        var displayPath = file.replaceFirst(packagePath, '');
        if (displayPath.startsWith('/') || displayPath.startsWith('\\')) {
          displayPath = displayPath.substring(1);
        }
        // Normalize to forward slashes for consistent display
        displayPath = displayPath.replaceAll('\\', '/');
        stdout.writeln('     ❌ $displayPath');
      }
    }

    stdout.writeln('');
  }

  return ProcessResult(sortedFiles.length, ignoredFilesList);
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

/// Load patterns from .gitignore file
List<String> _loadGitignorePatterns(String packagePath) {
  final patterns = <String>[];

  final gitignoreFile = File('$packagePath/.gitignore');
  if (!gitignoreFile.existsSync()) {
    return patterns;
  }

  try {
    final lines = gitignoreFile.readAsLinesSync();
    for (final line in lines) {
      final trimmed = line.trim();
      // Skip empty lines and comments
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      // Only include patterns that could match .dart files
      if (trimmed.endsWith('.dart') ||
          trimmed.contains('*') ||
          trimmed.endsWith('/') ||
          !trimmed.contains('.')) {
        patterns.add(trimmed);
      }
    }
  } catch (e) {
    // Ignore errors reading .gitignore
  }

  return patterns;
}

/// Check if a file path matches a gitignore pattern
bool _matchesGitignorePattern(String filePath, String pattern) {
  // Handle negation patterns (we skip them)
  if (pattern.startsWith('!')) {
    return false;
  }

  // Remove leading slash if present
  var cleanPattern = pattern.startsWith('/') ? pattern.substring(1) : pattern;

  // Handle directory patterns (ending with /)
  if (cleanPattern.endsWith('/')) {
    cleanPattern = cleanPattern.substring(0, cleanPattern.length - 1);
    // Check if file is inside this directory
    return filePath.startsWith('$cleanPattern/') || filePath.contains('/$cleanPattern/');
  }

  // Handle ** patterns (match any path)
  if (cleanPattern.contains('**')) {
    final regexPattern = cleanPattern
        .replaceAll('.', r'\.')
        .replaceAll('**/', '.*')
        .replaceAll('**', '.*')
        .replaceAll('*', '[^/]*')
        .replaceAll('?', '.');
    return RegExp('^$regexPattern\$').hasMatch(filePath) ||
           RegExp(regexPattern).hasMatch(filePath);
  }

  // Handle simple * patterns
  if (cleanPattern.contains('*')) {
    final regexPattern = cleanPattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '[^/]*')
        .replaceAll('?', '.');
    // Match anywhere in the path
    return RegExp(regexPattern).hasMatch(filePath);
  }

  // Handle patterns without wildcards
  // Match if file path contains the pattern as a directory or file name
  return filePath == cleanPattern ||
         filePath.endsWith('/$cleanPattern') ||
         filePath.startsWith('$cleanPattern/') ||
         filePath.contains('/$cleanPattern/');
}
