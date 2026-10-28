// 改 pubspec.yaml 里的 version 行。
//
// 被 test/release_version_test.dart 直接 import，所以这里的校验逻辑
// 就是**发版门禁本身**：它一旦放过畸形版本号，整条流水线就带着坏版本号出包。
//
// 拒绝带 build metadata 的版本（`1.2.3+4`）：Flutter 的 version 字段里
// `+` 后面那截是构建号，语义和 semver 的 build metadata 不是一回事，
// 混着用会在 CI 里造出「同一个版本号两个不同产物」。
//
// 跑：dart run tool/set_release_version.dart <version>
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

Version _parseReleaseVersion(String versionName) {
  final version = Version.parse(versionName);
  if (version.toString() != versionName || version.build.isNotEmpty) {
    throw const FormatException(
      'Use a semantic version without build metadata',
    );
  }
  return version;
}

bool isPrereleaseVersion(String versionName) =>
    _parseReleaseVersion(versionName).isPreRelease;

String updateReleaseVersion(
  String pubspec,
  String versionName,
  String buildNumber,
) {
  final version = _parseReleaseVersion(versionName);
  final build = int.tryParse(buildNumber);
  if (build == null || build <= 0 || build.toString() != buildNumber) {
    throw const FormatException('Use a positive build number');
  }
  final versionLine = RegExp(r'^version:.*$', multiLine: true);
  if (!versionLine.hasMatch(pubspec)) {
    throw const FormatException('pubspec.yaml is missing its version');
  }
  return pubspec.replaceFirst(versionLine, 'version: $version+$build');
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Usage: set_release_version.dart VERSION BUILD_NUMBER');
    exitCode = 64;
    return;
  }
  final pubspec = File('pubspec.yaml');
  try {
    final isPrerelease = isPrereleaseVersion(args[0]);
    final updated = updateReleaseVersion(
      await pubspec.readAsString(),
      args[0],
      args[1],
    );
    await pubspec.writeAsString(updated);
    final githubOutput = Platform.environment['GITHUB_OUTPUT'];
    if (githubOutput != null) {
      await File(githubOutput)
          .writeAsString('prerelease=$isPrerelease\n', mode: FileMode.append);
    }
  } on FormatException catch (error) {
    stderr.writeln('Invalid release: ${error.message}');
    exitCode = 64;
  }
}
