import 'package:battle_host/src/core/battle_state.dart';
import 'package:battle_host/src/orders/refusal.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// {@template order_plan}
/// What the rules make of an order now: refused, waiting until a time
/// (for AP or a busy weapon, COMBAT-06), or ready to apply.
/// {@endtemplate}
sealed class OrderPlan {
  /// {@macro order_plan}
  const new();
}

/// {@template plan_refused}
/// Refused by a rule or for its AP cost.
/// {@endtemplate}
final class PlanRefused extends OrderPlan {
  /// {@macro plan_refused}
  const new(this.refusal);

  /// Why.
  final OrderRefusal refusal;
}

/// {@template plan_waits}
/// Possible at [until], not before: the order is checked again then, on
/// the state of that time.
/// {@endtemplate}
final class PlanWaits extends OrderPlan {
  /// {@macro plan_waits}
  const new(this.until);

  /// When it can be carried out.
  final Duration until;
}

/// {@template plan_ready}
/// Possible now: [apply] changes the battle and gives the events.
/// {@endtemplate}
final class PlanReady extends OrderPlan {
  /// {@macro plan_ready}
  const new(this.apply);

  /// Carries the order out.
  final List<BattleEvent> Function() apply;
}

/// {@template order_check_context}
/// What the links of the chain learn about one order as they run: its
/// sender's section, its unit and the plan the rules make of it.
/// {@endtemplate}
final class OrderCheckContext {
  /// {@macro order_check_context}
  new({required this.command, required this.state});

  /// The command.
  final Command command;

  /// The battle's state.
  final BattleState state;

  /// The sender's section, once the sender link passed.
  SectionState? section;

  /// The unit of a unit order, once the right link passed.
  UnitState? unit;

  /// The plan, once the rules link ran.
  OrderPlan? plan;
}

/// One link of the order chain (Chain of Responsibility, stack decision
/// 7): it refuses the order or lets it go on to the next link.
abstract interface class OrderCheck {
  /// The refusal of this link, or null to go on.
  OrderRefusal? check(OrderCheckContext context);
}

/// {@template sender_check}
/// The first link: the sender's section exists, is the sender account's,
/// and its team is still in the battle.
/// {@endtemplate}
final class SenderCheck implements OrderCheck {
  /// {@macro sender_check}
  const new();

  @override
  OrderRefusal? check(OrderCheckContext context) {
    final sender = context.command.sender;
    final section = context.state.sections[sender.sectionId];
    if (section == null) {
      return const SenderRefused(SenderProblem.unknownSection);
    }
    if (section.accountId != sender.accountId) {
      return const SenderRefused(SenderProblem.notYourSection);
    }
    if (context.state.teams[section.team]!.eliminated) {
      return const SenderRefused(SenderProblem.teamEliminated);
    }
    context.section = section;
    return null;
  }
}

/// {@template right_check}
/// The second link: a unit order is for a unit of the sender's section on
/// the field (AI-01); the HQ moves on its manager's orders only (HQ-09,
/// HQ-10); only the server tells that a player logs in (decision 220).
/// {@endtemplate}
final class RightCheck implements OrderCheck {
  /// {@macro right_check}
  const new();

  @override
  OrderRefusal? check(OrderCheckContext context) {
    final section = context.section!;
    switch (context.command.order) {
      case UnitOrder(:final unitId):
        final unit = context.state.units[unitId];
        if (unit == null) return const RightRefused(RightProblem.unknownUnit);
        if (unit.sectionId != section.id) {
          return const RightRefused(RightProblem.notYourUnit);
        }
        if (!unit.onField) return const RightRefused(RightProblem.notOnField);
        context.unit = unit;
      case MoveHq():
        final manager = context.state.teams[section.team]!.managerAccountId;
        if (manager != context.command.sender.accountId) {
          return const RightRefused(RightProblem.notManager);
        }
      case EnterBattle():
        if (context.command.origin != Origin.server) {
          return const RightRefused(RightProblem.notServer);
        }
      case _:
        // Purchases, transfers and offers are the section's own.
        return null;
    }
    return null;
  }
}

/// {@template rules_check}
/// The third link: the rules of the order, through [planner], which also
/// prices it. A rule's refusal stops here.
/// {@endtemplate}
final class RulesCheck implements OrderCheck {
  /// {@macro rules_check}
  const new(this.planner);

  /// Makes the plan of an order.
  final OrderPlan Function(OrderCheckContext context) planner;

  @override
  OrderRefusal? check(OrderCheckContext context) {
    final plan = context.plan = planner(context);
    return plan is PlanRefused && plan.refusal is RuleRefused
        ? plan.refusal
        : null;
  }
}

/// {@template ap_check}
/// The last link: an order that costs more AP than the unit's maximum is
/// refused, since no wait would pay for it (COMBAT-06). An order that only
/// waits for AP goes through and waits.
/// {@endtemplate}
final class ApCheck implements OrderCheck {
  /// {@macro ap_check}
  const new();

  @override
  OrderRefusal? check(OrderCheckContext context) => switch (context.plan) {
    PlanRefused(:final ApRefused refusal) => refusal,
    _ => null,
  };
}
