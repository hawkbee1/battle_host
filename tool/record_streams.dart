// Records what the host sends each section over M5.15's scripted battle,
// in clear weather and in fog, for `battle_client`'s view tests (M6
// Issue 7): one binary host message per line, in hexadecimal.
//
// - `<weather>_<section>.hex`: from the start of the script;
// - `<weather>_<section>_late.hex`: from a subscription halfway;
// - `<weather>_<section>_host.hex`: the host's whole view of the section
//   at the end, the view a client must hold.
//
// Run from the package: dart run tool/record_streams.dart [output folder]
// (default ../battle_client/test/fixtures/streams).
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:battle_host/battle_host.dart';
import 'package:battle_protocol/battle_protocol.dart';

import '../test/helpers/scripted_battle.dart';

const _binary = BinaryProtocolCodec();

final class _Recorder implements SectionSubscriber {
  final messages = <HostMessage>[];

  @override
  void send(HostMessage message) => messages.add(message);
}

Future<void> main(List<String> arguments) async {
  final out = Directory(
    arguments.isEmpty ? '../battle_client/test/fixtures/streams' : arguments[0],
  )..createSync(recursive: true);
  for (final weather in ['clear', 'fog']) {
    final s = ScriptedHost.alone();
    await s.begin();
    s.battle.change(
      (state) => BattleState(
        victory: state.victory,
        units: state.units,
        sections: state.sections,
        teams: state.teams,
        relics: state.relics,
        delta: state.delta,
        offers: state.offers,
        dropped: state.dropped,
        weather: weather,
      ),
    );
    const sections = ['s-1', 's-2'];
    final early = {for (final id in sections) id: _Recorder()};
    final late = {for (final id in sections) id: _Recorder()};
    for (final MapEntry(:key, :value) in early.entries) {
      s.host.subscribe('b-1', key, value);
    }
    for (final (index, step) in script.indexed) {
      if (index == script.length ~/ 2) {
        for (final MapEntry(:key, :value) in late.entries) {
          s.host.subscribe('b-1', key, value);
        }
      }
      step(s);
    }
    for (final id in sections) {
      final host = _Recorder();
      s.host.subscribe('b-1', id, host);
      s.host.unsubscribe('b-1', host);
      _write(out, '${weather}_$id', early[id]!.messages);
      _write(out, '${weather}_${id}_late', late[id]!.messages);
      _write(out, '${weather}_${id}_host', [host.messages.first]);
    }
  }
}

void _write(Directory out, String name, List<HostMessage> messages) {
  final file = File('${out.path}/$name.hex')
    ..writeAsStringSync(messages.map((message) => '${_hex(message)}\n').join());
  print('wrote ${file.path}: ${messages.length} messages');
}

String _hex(HostMessage message) => _binary
    .encodeHostMessage(message)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
