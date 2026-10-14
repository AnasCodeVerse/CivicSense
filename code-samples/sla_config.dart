// CivicSense – complaint deadlines (SLA) and automatic escalation
//
// Every category has its own target time (e.g. water supply 1 day, potholes 7 days).
// Each complaint is labelled On track / Due soon / Overdue / Escalated, and once it
// passes 1.5x its target time it is escalated to Head Office.
//
// Excerpt from the CivicSense Flutter app. Full source available on request.

import 'package:flutter/material.dart';
import '../models/complaint.dart';
import 'constants.dart';

/// SLA (Service Level Agreement) configuration.
///
/// Every category has a target resolution time measured in days from the
/// complaint's `createdAt`. If the complaint isn't `resolved` by then, it
/// is "overdue". If it's overdue by 50% or more (e.g. a 7-day SLA hit
/// 10.5 days), it auto-escalates to Head Office attention.
///
/// These values are intentionally generous for v1 — the city administration can tighten them
/// after observing real resolution times. In v2 we'll let Head Office edit
/// them from the management console (stored in Firestore instead of code).
class SlaConfig {
  /// Per-category target resolution time, in days from createdAt.
  /// Categories not listed default to [defaultSlaDays].
  static const Map<IssueCategory, int> targetDays = {
    IssueCategory.waterSupply: 1,      // urgent — daily-life impact
    IssueCategory.sewerage: 1,          // urgent — health hazard
    IssueCategory.security: 1,          // urgent — safety
    IssueCategory.garbage: 2,           // quick — visible nuisance
    IssueCategory.streetLight: 3,       // moderate — safety implications
    IssueCategory.pothole: 7,           // standard — road repair cycle
    IssueCategory.strayAnimals: 7,      // standard — animal control coordination
    IssueCategory.other: 7,             // default for catch-all
    IssueCategory.parkMaintenance: 14,  // longer — planned work
    IssueCategory.encroachment: 30,     // longest — legal/notice process
    // `normal` is an AI internal state; if it ever ends up as a stored
    // category it gets the default below.
  };

  /// Fallback for any category not explicitly listed.
  static const int defaultSlaDays = 7;

  /// Once a complaint exceeds [targetDays] * this multiplier, it auto-escalates.
  /// 1.5 means a 7-day pothole escalates at day 10.5.
  /// Tuned so admins have a grace period before Head Office sees the ticket.
  static const double escalationMultiplier = 1.5;

  /// Returns the target resolution date for a complaint with the given
  /// creation time and category.
  static DateTime computeTargetDate(DateTime createdAt, IssueCategory category) {
    final days = targetDays[category] ?? defaultSlaDays;
    return createdAt.add(Duration(days: days));
  }

  /// Returns the date past which a complaint is considered escalated.
  /// = createdAt + (targetDays * escalationMultiplier).
  static DateTime computeEscalationDate(DateTime createdAt, IssueCategory category) {
    final days = targetDays[category] ?? defaultSlaDays;
    final escalationDays = (days * escalationMultiplier).round();
    return createdAt.add(Duration(days: escalationDays));
  }
}

/// SLA state of a complaint right now. Computed at read time — does NOT
/// require a server-side job.
enum SlaStatus {
  /// Resolved and verified — SLA is moot.
  closed,

  /// Still well within the deadline.
  onTrack,

  /// Within 24 hours of the deadline or already past it but not yet escalated.
  dueSoon,

  /// Past the SLA target — admin needs to act.
  overdue,

  /// Past the escalation threshold — Head Office should see this.
  escalated,
}

extension SlaStatusX on SlaStatus {
  String get label {
    switch (this) {
      case SlaStatus.closed:
        return 'Closed';
      case SlaStatus.onTrack:
        return 'On track';
      case SlaStatus.dueSoon:
        return 'Due soon';
      case SlaStatus.overdue:
        return 'Overdue';
      case SlaStatus.escalated:
        return 'Escalated';
    }
  }

  Color get color {
    switch (this) {
      case SlaStatus.closed:
        return AppColors.textSecondary;
      case SlaStatus.onTrack:
        return AppColors.success;
      case SlaStatus.dueSoon:
        return AppColors.warning;
      case SlaStatus.overdue:
        return AppColors.error;
      case SlaStatus.escalated:
        return const Color(0xFF8E0000); // dark red — visually distinct from overdue
    }
  }

  IconData get icon {
    switch (this) {
      case SlaStatus.closed:
        return Icons.check_circle_outline;
      case SlaStatus.onTrack:
        return Icons.schedule;
      case SlaStatus.dueSoon:
        return Icons.access_time;
      case SlaStatus.overdue:
        return Icons.error_outline;
      case SlaStatus.escalated:
        return Icons.priority_high;
    }
  }
}

/// SLA-related computations on a Complaint. All values are computed at read
/// time from `createdAt`, `category`, and `status` — no server-side job
/// needed. Read-time computation is the trade-off we took for v1: no
/// automatic notifications when a complaint crosses the overdue threshold,
/// but no infrastructure cost either. V2 moves this to a Cloud Function.
extension ComplaintSlaX on Complaint {
  /// The effective SLA target. Prefers the stored `slaTargetDate` (stamped
  /// at submit) so changes to SlaConfig.targetDays don't retroactively shift
  /// old tickets' deadlines. Falls back to the current config for legacy
  /// complaints that don't have the stored value.
  DateTime get effectiveSlaTargetDate {
    return slaTargetDate ?? SlaConfig.computeTargetDate(createdAt, category);
  }

  /// Effective escalation date — slaTargetDate * SlaConfig.escalationMultiplier.
  DateTime get effectiveEscalationDate {
    final target = effectiveSlaTargetDate;
    final slaMicros = target.difference(createdAt).inMicroseconds;
    final escalationMicros =
        (slaMicros * SlaConfig.escalationMultiplier).round();
    // Using the duration delta between createdAt and slaTargetDate (rather
    // than recomputing from config) means legacy complaints honour their
    // original SLA window when escalating.
    return createdAt.add(Duration(microseconds: escalationMicros));
  }

  /// Current SLA state. Resolved complaints are always [SlaStatus.closed].
  SlaStatus get slaStatus {
    if (status == ComplaintStatus.resolved && !verificationPending) {
      return SlaStatus.closed;
    }
    final now = DateTime.now();
    final target = effectiveSlaTargetDate;
    final escalation = effectiveEscalationDate;

    if (now.isAfter(escalation)) return SlaStatus.escalated;
    if (now.isAfter(target)) return SlaStatus.overdue;
    // Within 24 hours of target → due soon.
    if (target.difference(now).inHours <= 24) return SlaStatus.dueSoon;
    return SlaStatus.onTrack;
  }

  bool get isOverdue =>
      slaStatus == SlaStatus.overdue || slaStatus == SlaStatus.escalated;

  bool get isEscalated => slaStatus == SlaStatus.escalated;

  /// Human-readable time-until-due. Negative = overdue.
  /// Examples: "Due in 3d", "Due in 4h", "Overdue by 2d", "Resolved".
  String get slaTimeLabel {
    if (slaStatus == SlaStatus.closed) return 'Resolved';
    final now = DateTime.now();
    final target = effectiveSlaTargetDate;
    final diff = target.difference(now);

    if (diff.isNegative) {
      final overdueDur = diff.abs();
      if (overdueDur.inDays > 0) {
        return 'Overdue by ${overdueDur.inDays}d';
      }
      return 'Overdue by ${overdueDur.inHours}h';
    }

    if (diff.inDays > 0) return 'Due in ${diff.inDays}d';
    if (diff.inHours > 0) return 'Due in ${diff.inHours}h';
    return 'Due in <1h';
  }
}
