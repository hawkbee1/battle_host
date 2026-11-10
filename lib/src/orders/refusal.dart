final _capital = RegExp('[A-Z]');

String _code(Enum reason) =>
    reason.name.replaceAllMapped(_capital, (m) => '_${m[0]!.toLowerCase()}');

/// The link of the order chain that refuses an order (Chain of
/// Responsibility, stack decision 7), in the order they run.
enum CheckLink {
  /// The rate limit of the sender (AI-03).
  rate,

  /// The sender: its section, account and team.
  sender,

  /// Its right to act: its own unit, the HQ manager for the HQ.
  right,

  /// The rules of the order.
  rules,

  /// The AP it costs.
  ap,
}

/// {@template order_refusal}
/// Why an order was refused: one sealed type for the whole chain. It wraps
/// the refusal enums of the rules core (`Refusal`, `WeaponRefusal`,
/// `ActionRefusal`, ...) rather than replacing them, so `battle_rules`
/// stays usable alone. A refused order changes nothing.
/// {@endtemplate}
sealed class OrderRefusal {
  /// {@macro order_refusal}
  const new();

  /// The link that refused it.
  CheckLink get link;

  /// Its code, the `reason` of the protocol's `OrderRefused`.
  String get code;

  @override
  String toString() => '${link.name}: $code';
}

/// {@template rate_refused}
/// The sender sent more orders than its rate allows (AI-03): the same
/// limit for players and AI agents.
/// {@endtemplate}
final class RateRefused extends OrderRefusal {
  /// {@macro rate_refused}
  const new();

  @override
  CheckLink get link => CheckLink.rate;

  @override
  String get code => 'rate_limited';
}

/// What is wrong with a sender.
enum SenderProblem {
  /// The battle has no such section.
  unknownSection,

  /// The section is another account's.
  notYourSection,

  /// The section's team is out of the battle (HQ-18).
  teamEliminated,

  /// The battle has ended.
  battleOver,
}

/// {@template sender_refused}
/// The sender may not send orders here.
/// {@endtemplate}
final class SenderRefused extends OrderRefusal {
  /// {@macro sender_refused}
  const new(this.problem);

  /// What is wrong.
  final SenderProblem problem;

  @override
  CheckLink get link => CheckLink.sender;

  @override
  String get code => _code(problem);
}

/// What the sender has no right to.
enum RightProblem {
  /// The battle has no such unit.
  unknownUnit,

  /// The unit is another section's (AI-01: a unit acts only on its
  /// player's orders).
  notYourUnit,

  /// The unit is not on the field.
  notOnField,

  /// Only the HQ manager moves the HQ (HQ-09, HQ-10).
  notManager,

  /// Only the server tells that a player logs in (decision 220).
  notServer,
}

/// {@template right_refused}
/// The sender has no right to give this order.
/// {@endtemplate}
final class RightRefused extends OrderRefusal {
  /// {@macro right_refused}
  const new(this.problem);

  /// What is wrong.
  final RightProblem problem;

  @override
  CheckLink get link => CheckLink.right;

  @override
  String get code => _code(problem);
}

/// {@template rule_refused}
/// A rule refuses the order: [reason] is a refusal of the rules core or of
/// the host's own checks (`HostRule`).
/// {@endtemplate}
final class RuleRefused extends OrderRefusal {
  /// {@macro rule_refused}
  const new(this.reason);

  /// The rule's refusal.
  final Enum reason;

  @override
  CheckLink get link => CheckLink.rules;

  @override
  String get code => _code(reason);
}

/// {@template ap_refused}
/// The order costs more AP than the unit's maximum, so no wait would pay
/// for it (COMBAT-06).
/// {@endtemplate}
final class ApRefused extends OrderRefusal {
  /// {@macro ap_refused}
  const new();

  @override
  CheckLink get link => CheckLink.ap;

  @override
  String get code => 'cost_above_ap_max';
}

/// The host's own reasons to refuse an order, beside those of the rules
/// core.
enum HostRule {
  /// The position or cell is off the map.
  offMap,

  /// No path reaches the goal.
  noPath,

  /// The client's path does not start where the mover stands.
  pathNotFromMover,

  /// A carried unit does not move on its own.
  carried,

  /// Its loaded weapon forbids moving (`move_while_loaded`).
  weaponLoaded,

  /// A scout cannot move while it observes (UNIT-34).
  observing,

  /// The battle has no such target.
  unknownTarget,

  /// The target is out of the weapon's range.
  outOfRange,

  /// The unit does not see its target itself (COMBAT-11).
  targetNotSeen,

  /// The weapon cannot hit a flying target (COMBAT-25).
  cannotHitFlying,

  /// The weapon does not fire at a position (COMBAT-12, COMBAT-55).
  notIndirect,

  /// Nobody of the section sees the position and no scout reports it
  /// through a radio (COMBAT-12).
  positionNotSeen,

  /// The weapon is not aimed in first person (decision 183).
  notAimed,

  /// The battle has no such dropped weapon.
  unknownDropped,

  /// The unit is not where the weapon lies (COMBAT-30).
  notOnTheSpot,

  /// The unit cannot fly.
  cannotFly,

  /// It is not flying.
  notFlying,

  /// It is flying already.
  alreadyFlying,

  /// The target is not a transport.
  notATransport,

  /// The unit cannot be carried (UNIT-36: radios).
  notTransportable,

  /// The unit weighs more than the transport takes per unit (UNIT-37).
  tooHeavy,

  /// The transport carries all the weight it can (UNIT-37).
  transportFull,

  /// The unit is not carried.
  notCarried,

  /// The transport is flying.
  transportFlying,

  /// The transport is recalled: it takes no passengers (HQ-49).
  transportRecalled,

  /// The unit is not within the storage radius of its storage place
  /// (HQ-31): a recall stores it from anywhere.
  notAtStorage,

  /// The battle has no unit type, weapon type or stat of that name.
  unknownType,

  /// The test unit is bought only in a battle whose settings allow test
  /// units (UNIT-44, decision 239).
  testUnitsOff,

  /// The battle has no such section.
  unknownSection,

  /// A section does not send money or offers to itself.
  toItself,

  /// The battle has no such offer waiting.
  unknownOffer,

  /// Only the owner of the prisoners answers an offer (COMBAT-44).
  notYourOffer,

  /// A prisoner buys nothing and is not deployed (COMBAT-43).
  isPrisoner,

  /// The target is further than the unit reaches.
  tooFar,

  /// An encampment never goes onto a floating island (MAP-38).
  islandUnreachable,

  /// No interrupted build or repair has that ID.
  unknownWork,

  /// The battle has no such relic.
  unknownRelic,

  /// The team owns the relic already.
  alreadyOwned,
}
