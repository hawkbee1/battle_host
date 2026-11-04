import 'dart:io';

import 'package:battle_host/src/ports/map_source.dart';
import 'package:battle_map/battle_map.dart';

/// {@template directory_map_source}
/// Reads built maps from a folder (Adapter): `<root>/<map ID>/map.yaml`
/// and `tiles/<column>_<row>/` with `heights.png`, `terrain.png` and
/// `objects.yaml`, as the map builder writes them.
/// {@endtemplate}
final class DirectoryMapSource implements MapSource {
  /// {@macro directory_map_source}
  const new(this.root);

  /// The folder of the maps.
  final String root;

  @override
  BuiltMapFiles read(String mapId) {
    final folder = '$root/$mapId';
    return BuiltMapFiles(
      mapYaml: File('$folder/$mapFile').readAsStringSync(),
      tiles: {
        for (final tile in Directory('$folder/tiles').listSync())
          if (tile is Directory)
            tile.uri.pathSegments.lastWhere((s) => s.isNotEmpty): TileFiles(
              heightsPng: File('${tile.path}/heights.png').readAsBytesSync(),
              terrainPng: File('${tile.path}/terrain.png').readAsBytesSync(),
              objectsYaml: File('${tile.path}/$objectsFile').readAsStringSync(),
            ),
      },
    );
  }
}
