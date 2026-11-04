import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

/// Member names of `uniform <block> { ... }` in GLSL source, in order.
List<String> blockMembers(String src, String block) {
  final m = RegExp('uniform $block\\s*\\{([^}]*)\\}').firstMatch(src)!;
  return RegExp(r'vec4\s+(\w+)').allMatches(m.group(1)!).map((x) => x.group(1)!).toList();
}

void main() {
  // The Dart packers (lib/src/uniforms.dart) assume these exact orders.
  test('SimInfo block order', () {
    final src = File('shaders/sim_step.frag').readAsStringSync();
    expect(blockMembers(src, 'SimInfo'), ['size', 'wave', 'drops']);
    expect(src, contains('vec4 drops[4]'));
  });

  test('FrameInfo block order', () {
    final src = File('shaders/water_surface.frag').readAsStringSync();
    expect(blockMembers(src, 'FrameInfo'),
        ['screen', 'cam', 'domain', 'sim', 'look', 'moonDir', 'moonRight', 'moonUp', 'stars',
         'sun', 'sunLight', 'day', 'cloud', 'wind', 'cirrus', 'plates', 'nightMoon', 'night']);
  });

  test('NoiseInfo block and the cloud layer scales match the Dart side', () {
    final noise = File('shaders/cloud_noise.frag').readAsStringSync();
    expect(blockMembers(noise, 'NoiseInfo'), ['size']);
    final src = File('shaders/water_surface.frag').readAsStringSync();
    expect(src, contains('DETAIL_SCALE = ${SkyClouds.detailScale};'));
    expect(src, contains('CIRRUS_SCALE = ${SkyClouds.cirrusScale};'));
    final names = ['PLATE_A1', 'PLATE_A2', 'PLATE_B1', 'PLATE_B2'];
    for (var i = 0; i < 4; i++) {
      expect(src, contains('const vec4 ${names[i]} = ${SkyClouds.plateLayers[i].glsl};'));
    }
    expect(src, contains('uniform sampler2D plateA;'));
    expect(src, contains('uniform sampler2D plateB;'));
  });

  test('the compiled bundle is present and newer than every shader source', () {
    final bundle = File('assets/water.shaderbundle');
    expect(bundle.existsSync(), isTrue);
    final bytes = bundle.readAsBytesSync();
    final text = String.fromCharCodes(bytes);
    for (final name in ['FullscreenVertex', 'SimStepFragment', 'WaterSurfaceFragment', 'CloudNoiseFragment']) {
      expect(text, contains(name));
    }
    final built = bundle.lastModifiedSync();
    for (final f in Directory('shaders').listSync().whereType<File>()) {
      expect(f.lastModifiedSync().isAfter(built), isFalse,
          reason: '${f.path} changed after the bundle; run tool/build_shaders.sh');
    }
  });
}
