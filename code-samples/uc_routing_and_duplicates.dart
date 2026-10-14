// CivicSense – routing complaints to the right Union Council, and catching duplicates
//
// 1. Each Union Council (UC) is stored as one or more polygons on the map.
//    When a resident submits a report, a point-in-polygon check (ray casting)
//    finds which UC the location falls inside, and the complaint goes to that UC.
// 2. Before a new report is saved, we look for an open complaint of the same
//    category within 50 m in the last 7 days, and ask the resident if it's the same issue.
//
// Excerpt from complaint_service.dart in the CivicSense Flutter app.
// Firestore setup and unrelated methods are omitted. Full source available on request.

import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/complaint.dart';

class LatLngPoint {
  final double lat;
  final double lng;
  const LatLngPoint(this.lat, this.lng);
}

/// A Union Council (UC) – one local area that complaints are routed to.
///
/// A UC can be made up of one OR MORE non-contiguous land parcels.
/// Each parcel is its own closed polygon. The `boundaries` field is a list
/// of these polygons; a point is "inside this UC" if it's inside ANY of
/// them. Real areas are often split by rivers or highways into separate parcels.
class UnionCouncil {
  final String id;
  final String name;
  final String area;

  /// List of polygons. Each polygon is a list of points forming a closed
  /// boundary. Most UCs will have exactly one polygon; some have two or more.
  final List<List<LatLngPoint>> boundaries;

  const UnionCouncil({
    required this.id,
    required this.name,
    required this.area,
    required this.boundaries,
  });

  /// Convenience getter — returns the FIRST polygon's points. Used by
  /// legacy callers that pre-date multi-parcel support and only ever
  /// expected one boundary. Returns empty list if the phase has no
  /// polygons (shouldn't happen with valid data).
  ///
  /// New code should use `boundaries` directly. This shim is here to
  /// keep existing screens working without forcing a full refactor.
  List<LatLngPoint> get boundary =>
      boundaries.isNotEmpty ? boundaries.first : const [];

  /// Build from the JSON shape defined in `assets/ucs.json`.
  ///
  /// Accepts BOTH shapes:
  ///   - Legacy: `"boundary": [ {lat, lng}, ... ]` — single polygon
  ///   - New:    `"boundaries": [ [ {lat, lng}, ... ], [ ... ] ]` — multiple
  ///
  /// This lets us evolve `ucs.json` over time without breaking older
  /// snapshots someone might have.
  factory UnionCouncil.fromJson(Map<String, dynamic> json) {
    final List<List<LatLngPoint>> parsed = [];

    if (json['boundaries'] is List) {
      // New multi-parcel shape.
      for (final poly in (json['boundaries'] as List)) {
        if (poly is List) {
          parsed.add(poly
              .map((p) => LatLngPoint(
                    (p['lat'] as num).toDouble(),
                    (p['lng'] as num).toDouble(),
                  ))
              .toList());
        }
      }
    } else if (json['boundary'] is List) {
      // Legacy single-polygon shape.
      final boundaryJson = json['boundary'] as List<dynamic>;
      parsed.add(boundaryJson
          .map((p) => LatLngPoint(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList());
    }

    return UnionCouncil(
      id: json['id'] as String,
      name: json['name'] as String,
      area: json['area'] as String,
      boundaries: parsed,
    );
  }
}

class ComplaintService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  CollectionReference get _complaints => _firestore.collection('complaints');

  // UCs are loaded once at startup from assets/ucs.json (loader omitted here).
  static List<UnionCouncil> _phases = const [];

  UnionCouncil? getUCForLocation(double lat, double lng) {
    final point = LatLngPoint(lat, lng);
    for (final uc in _phases) {
      // Check each parcel. A point inside ANY parcel of a phase means
      // the point is in that phase. First match wins — if two phases
      // overlap (they shouldn't, but defensively), the order in
      // ucs.json determines the result.
      for (final polygon in uc.boundaries) {
        if (polygon.isEmpty) continue;
        if (_isPointInPolygon(point, polygon)) {
          return uc;
        }
      }
    }
    return null;
  }

  bool _isPointInPolygon(LatLngPoint point, List<LatLngPoint> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      if ((polygon[i].lng > point.lng) != (polygon[j].lng > point.lng) &&
          point.lat <
              (polygon[j].lat - polygon[i].lat) *
                      (point.lng - polygon[i].lng) /
                      (polygon[j].lng - polygon[i].lng) +
                  polygon[i].lat) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _toRad(double deg) => deg * pi / 180;

  // ---------------------------------------------------------------------------
  // DUPLICATE DETECTION
  //
  // Before submitting a new complaint, the report screen calls
  // [findPotentialDuplicates] to surface any existing OPEN complaint that
  // could be the same issue. We use four signals:
  //   1. Same phase (ucId) — strong: residents in different phases shouldn't
  //      see each other's complaints anyway
  //   2. Same category — strong: a pothole and a stray dog at the same
  //      location are different issues
  //   3. Within 50m radius — moderate: GPS pins have ~10-15m noise from
  //      typical phones, so 50m is generous enough to catch real duplicates
  //   4. Created within last 7 days — moderate: anything older is likely a
  //      separate occurrence even if pothole reappears in same spot
  //
  // We deliberately do NOT use image similarity here — it would require
  // server-side compute and gives diminishing returns. Phase + category +
  // 50m + 7-day window catches the meaningful duplicates.
  //
  // Returns at most 3 candidates ordered by distance (closest first).
  // The report screen shows these in a "did you mean..." dialog.
  // ---------------------------------------------------------------------------
  static const double duplicateRadiusMeters = 50.0;
  static const int duplicateWindowDays = 7;

  Future<List<Complaint>> findPotentialDuplicates({
    required String ucId,
    required IssueCategory category,
    required double latitude,
    required double longitude,
  }) async {
    // Skip the check for unassigned (out-of-phase) submissions — the radius
    // filter doesn't make sense across the whole map.
    if (ucId.isEmpty || ucId == 'unassigned') return const [];

    final cutoff =
        DateTime.now().subtract(const Duration(days: duplicateWindowDays));

    // Defensive timeout. The duplicate query relies on a composite Firestore
    // index. If the index is missing, still building, or the network is
    // degraded, Firestore can hang silently instead of throwing. Without
    // this timeout the submit UI would spin forever (real bug observed
    // during testing). 10 seconds is generous — a working index returns
    // results in <500ms even with hundreds of complaints.
    //
    // On timeout, we treat the result as "no duplicates found" so the
    // user's submission can still proceed. The original submission is
    // never blocked by a slow dup-check. Worst case: a real duplicate
    // gets created, which the admin can merge later. That's a much better
    // failure mode than a forever-loading spinner.
    try {
      final snap = await _complaints
          .where('ucId', isEqualTo: ucId)
          .where('category', isEqualTo: category.name)
          .where('status', whereIn: [
            ComplaintStatus.pending.name,
            ComplaintStatus.inProgress.name,
          ])
          .where('createdAt', isGreaterThan: Timestamp.fromDate(cutoff))
          .get()
          .timeout(const Duration(seconds: 10));

      final candidates = snap.docs
          .map((d) => Complaint.fromFirestore(d))
          .where((c) =>
              _distanceMeters(latitude, longitude, c.latitude, c.longitude) <=
              duplicateRadiusMeters)
          .toList();

      // Sort by distance from the new submission. The user sees the closest
      // (most-likely-duplicate) first in the dialog.
      candidates.sort((a, b) {
        final da =
            _distanceMeters(latitude, longitude, a.latitude, a.longitude);
        final db =
            _distanceMeters(latitude, longitude, b.latitude, b.longitude);
        return da.compareTo(db);
      });

      return candidates.take(3).toList();
    } on TimeoutException {
      // Timeout — treat as "no duplicates found" so the submission can
      // proceed. Log so this is visible during dev.
      debugPrint(
          '⚠️ Duplicate check timed out after 10s. Continuing without dup detection.');
      return const [];
    } catch (e, stack) {
      // Any other Firestore error (missing index, permission denied, etc).
      // Same fallback — fail open so the user can still submit.
      debugPrint('⚠️ Duplicate check failed: $e');
      debugPrint('   Stack: $stack');
      return const [];
    }
  }

  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    return _distanceKm(lat1, lng1, lat2, lng2) * 1000;
  }
}
