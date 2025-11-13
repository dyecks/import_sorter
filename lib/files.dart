// 🎯 Dart imports:
import 'dart:io';

// 📦 Package imports:
import 'package:yaml/yaml.dart';

/// Get all the dart files for the project and the contents
Map<String, File> dartFiles(String currentPath, List<String> args) {
  final dartFiles = <String, File>{};

  // Check if this is a workspace configuration
  final workspacePackages = _getWorkspacePackages(currentPath);

  List<FileSystemEntity> allContents = [];

  if (workspacePackages.isNotEmpty) {
    // If workspace is detected, scan all packages in the workspace
    for (final packagePath in workspacePackages) {
      allContents.addAll([
        ..._readDir(packagePath, 'lib'),
        ..._readDir(packagePath, 'bin'),
        ..._readDir(packagePath, 'test'),
        ..._readDir(packagePath, 'tests'),
        ..._readDir(packagePath, 'test_driver'),
        ..._readDir(packagePath, 'integration_test'),
      ]);
    }
  } else {
    // Standard project structure
    allContents = [
      ..._readDir(currentPath, 'lib'),
      ..._readDir(currentPath, 'bin'),
      ..._readDir(currentPath, 'packages'),
      ..._readDir(currentPath, 'test'),
      ..._readDir(currentPath, 'tests'),
      ..._readDir(currentPath, 'test_driver'),
      ..._readDir(currentPath, 'integration_test'),
    ];
  }

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

List<FileSystemEntity> _readDir(String currentPath, String name) {
  if (Directory('$currentPath/$name').existsSync()) {
    return Directory('$currentPath/$name').listSync(recursive: true);
  }
  return [];
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
    // and fall back to standard project structure
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
