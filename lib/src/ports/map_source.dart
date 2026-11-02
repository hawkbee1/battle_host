import 'package:battle_map/battle_map.dart';

/// Where the host reads its maps (a port): the built tiles of a map, by
/// its ID. The adapter reads them from disk; tests pass them in memory.
abstract interface class MapSource {
  /// The built files of the map [mapId].
  BuiltMapFiles read(String mapId);
}
