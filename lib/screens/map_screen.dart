import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/shared_bottom_nav.dart';
import '../theme/app_theme.dart';
import '../services/journey_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import '../services/auth_service.dart';
import '../services/map_marker_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:math' show cos, sin, sqrt, asin;
import 'dart:ui' as ui;

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const CameraPosition _kDelhi = CameraPosition(
    target: LatLng(28.6139, 77.2090),
    zoom: 14.4746,
  );

  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  GoogleMapController? _mapController;
  String _instruction = "Follow the route";
  String _distance = "Not Started";
  String _duration = "Not";
  String _fromAddress = "Start Location";
  String _toAddress = "Destination";
  List<dynamic> _steps = [];
  bool _routeFetched = false;
  bool _showSteps = false;

  bool _followingUser = true;
  StreamSubscription<Position>? _positionStream;
  BitmapDescriptor? _userIcon;
  LatLng? _currentPos;
  LatLng? _startLatLng;
  LatLng? _destLatLng;
  BitmapDescriptor? _redDotIcon;

  // Route animation
  List<LatLng> _routePoints = [];
  Timer? _animationTimer;
  bool _isAnimating = false;
  double _pausedTraveledMeters = 0.0; // Tracks progress for resume
  String? _vehicleType; // From HomeScreen navigation args

  // Accident Alert variables
  Map<String, List<Map<String, String>>> _groupedAlerts = {};
  int _totalAlertsShown = 0;
  String _currentCategory = "Good Driving";
  int _currentStepIndex = -1;
  final List<double> _stepDistances = [];
  bool _isShowingNavAlert = false;
  Timer? _navAlertPriorityTimer;
  late FlutterTts _flutterTts;

  String _alertHeading = "Stay Alert";
  String _alertSubtext = "Please be alert.";
  Timer? _alertTimer;
  final ScrollController _alertScrollController = ScrollController();
  final ScrollController _incidentsScrollController = ScrollController();
  Map<String, dynamic>? _activeSosEvent; // Currently triggered precise SOS
  final Set<String> _triggeredSosIds = {}; // Track SOS alerts already triggered
  RealtimeChannel? _messageChannel;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
    _initUserIcon();
    _initRedDotIcon();
    _loadAccidentData();
    _initTts();
    _fetchGlobalSOS();
    _initMessageListener();
  }

  void _initMessageListener() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    _messageChannel = Supabase.instance.client
        .channel('user_messages_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'tracking_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final senderName = newRecord['sender_name'] ?? 'Tracker';
            final message = newRecord['message'] ?? '';

            if (mounted) {
              _showTrackerMessageDialog(senderName, message);
            }
          },
        )
        .subscribe();
  }

  void _showTrackerMessageDialog(String sender, String message) {
    // Speak the message for safety
    _speak("Message from $sender. $message");

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.message_rounded, color: AppTheme.primaryOrange),
            const SizedBox(width: 12),
            Text(
              'Message from $sender',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryOrange,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('ACKNOWLEDGE'),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchGlobalSOS() async {
    final journeyService = Provider.of<JourneyService>(context, listen: false);
    await journeyService.fetchAllGlobalSOS();
    journeyService.initRealtimeSOS(); // Start listening for live updates
  }

  Future<void> _initRedDotIcon() async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = Colors.red;
    const double radius = 8.0;
    canvas.drawCircle(const Offset(radius, radius), radius, paint);

    final ui.Image image = await pictureRecorder.endRecording().toImage(
      (radius * 2).toInt(),
      (radius * 2).toInt(),
    );
    final ByteData? byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData != null) {
      setState(() {
        _redDotIcon = BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
      });
    }
  }

  void _initTts() {
    _flutterTts = FlutterTts();
    _flutterTts.setLanguage("en-US");
    _flutterTts.setPitch(1.0);
    _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _speak(String text) async {
    if (text.isNotEmpty) {
      await _flutterTts.speak(text);
    }
  }

  Future<void> _initUserIcon() async {
    final authService = Provider.of<AuthService>(context, listen: false);

    // Attempt to refresh profile if local profile is null
    if (authService.userPhotoUrl == null) {
      await authService.getProfile();
    }

    final photoUrl = authService.userPhotoUrl;
    try {
      final icon = await MapMarkerService.getProfileMarker(photoUrl);
      if (mounted) {
        setState(() {
          _userIcon = icon;
          _updateMarkers();
        });
      }
    } catch (e) {
      debugPrint("Error loading user icon in MapScreen: $e");
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _animationTimer?.cancel();
    _alertTimer?.cancel();
    _navAlertPriorityTimer?.cancel();
    _alertScrollController.dispose();
    _incidentsScrollController.dispose();
    _flutterTts.stop();
    _messageChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (permission == LocationPermission.deniedForever) return;

    // Fast initial location fetch for immediate feedback
    try {
      // Try last known first (Mobile only)
      if (!kIsWeb) {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null && mounted) {
          setState(() {
            _currentPos = LatLng(lastPos.latitude, lastPos.longitude);
            _updateMarkers();
          });
        }
      }

      // Then get a quick medium-accuracy current position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 10)); // Increased timeout

      if (mounted) {
        setState(() {
          _currentPos = LatLng(position.latitude, position.longitude);
          _updateMarkers();
        });
      }
    } catch (e) {
      debugPrint("Initial location fetch error in MapScreen: $e");
    }

    _startLocationUpdates();
  }

  void _startLocationUpdates() {
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0, // Set to 0 for immediate feedback on movement
          ),
        ).listen((Position position) async {
          final newPos = LatLng(position.latitude, position.longitude);
          final journeyService = Provider.of<JourneyService>(
            context,
            listen: false,
          );
          journeyService.updateIconPosition(newPos);

          if (_currentPos != null && _isAnimating) {
            final double dist = _haversineMeters(_currentPos!, newPos);
            // Trigger new alert if moved more than 30m
            if (dist > 30.0) {
              _showNextAlert();
            }
          }

          setState(() {
            _currentPos = newPos;
            _updateMarkers();
          });

          if (_followingUser && _mapController != null) {
            _mapController!.animateCamera(CameraUpdate.newLatLng(newPos));
          }

          _checkProximityAlerts();
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeFetched) {
      final journeyService = Provider.of<JourneyService>(
        context,
        listen: false,
      );
      final activeJourney = journeyService.activeJourney;
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

      final sourceData = activeJourney ?? args;

      if (sourceData != null && sourceData['dest'] != null) {
        _routeFetched = true;
        _fromAddress = sourceData['startName'] ?? "Your Location";
        _toAddress = sourceData['destName'] ?? "---";
        _destLatLng = sourceData['dest'];
        _vehicleType = sourceData['vehicleType'] as String?;

        // Use the passed start location as the FIXED starting point for the route
        _startLatLng =
            sourceData['start'] ??
            _currentPos ??
            const LatLng(28.6139, 77.2090);

        _updateMarkers();
        _getRoute(_startLatLng!, _destLatLng!);
      }
    }
  }

  Future<void> _getRoute(LatLng start, LatLng dest) async {
    final journeyService = Provider.of<JourneyService>(context, listen: false);
    setState(() => _instruction = "Requesting route info...");

    try {
      final data = await journeyService.getDirections(start, dest);
      if (data != null &&
          data["status"] == "OK" &&
          data["routes"] != null &&
          data["routes"].isNotEmpty) {
        final legs = data["routes"][0]["legs"][0];
        final points = await journeyService.getPolylinePoints(start, dest);

        setState(() {
          _distance = legs["distance"]["text"];
          _duration = legs["duration"]["text"];
          _steps = legs["steps"] ?? [];

          if (_steps.isNotEmpty) {
            _instruction = _steps[0]["html_instructions"].replaceAll(
              RegExp(r'<[^>]*>|&[^;]+;'),
              ' ',
            );
          } else {
            _instruction = "Follow the route";
          }

          _polylines.clear();
          _polylines.add(
            Polyline(
              polylineId: const PolylineId("route"),
              points: points,
              color: AppTheme.primaryOrange,
              width: 6,
            ),
          );

          _routePoints = List<LatLng>.from(points);
          _calculateStepBoundaries();
          _startLatLng = start;
          _destLatLng = dest;
          _updateMarkers();
        });

        _fitBounds(start, dest);

        // Calculate initial traveled distance if we are resuming
        final elapsed = journeyService.elapsedSeconds;
        final speedMs = _vehicleSpeedMs();
        double initialMeters = 0.0;
        if (elapsed > 0 && journeyService.activeJourney != null) {
          initialMeters = elapsed * speedMs;
          debugPrint(
            'Resuming journey: $elapsed seconds elapsed, starting at ${initialMeters.toStringAsFixed(1)}m',
          );
        }

        // Automatic animation trigger removed. Use 'DEMO' button to start animation.
        // Future.delayed(
        //   const Duration(seconds: 2),
        //   () => _startRouteAnimation(initialTraveledMeters: initialMeters),
        // );
      } else {
        setState(
          () => _instruction =
              "Unable to fetch route. This might be due to browser CORS restrictions on Web.",
        );
      }
    } catch (e) {
      debugPrint("Routing error: $e");
      setState(() => _instruction = "Network error while fetching route.");
    }
  }

  void _updateMarkers() {
    final Set<Marker> newMarkers = {};

    // User Marker
    if (_currentPos != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('user_pos'),
          position: _currentPos!,
          icon:
              _userIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'You'),
          anchor: const Offset(0.5, 0.5),
          zIndex: 10,
        ),
      );
    }

    // Start Marker (Green)
    if (_startLatLng != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId("start"),
          position: _startLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      );
    }

    // Destination Marker
    if (_destLatLng != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId("dest"),
          position: _destLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      );
    }

    setState(() {
      _markers.clear();
      _markers.addAll(newMarkers);
    });
  }

  void _fitBounds(LatLng start, LatLng dest) {
    if (_mapController == null) return;

    final southwest = LatLng(
      start.latitude < dest.latitude ? start.latitude : dest.latitude,
      start.longitude < dest.longitude ? start.longitude : dest.longitude,
    );
    final northeast = LatLng(
      start.latitude > dest.latitude ? start.latitude : dest.latitude,
      start.longitude > dest.longitude ? start.longitude : dest.longitude,
    );

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: southwest, northeast: northeast),
        100,
      ),
    );
  }

  /// Returns speed in m/s for the vehicle type selected on Home Screen
  double _vehicleSpeedMs() {
    final type = (_vehicleType ?? '').toLowerCase();
    if (type.contains('two')) return 11.0; // ~40 km/h (bike/scooter)
    if (type.contains('three')) return 8.0; // ~30 km/h (auto/tuk-tuk)
    if (type.contains('four')) return 14.0; // ~50 km/h (car)
    return 11.0; // default: two-wheeler
  }

  /// Great-circle distance between two LatLng points in meters
  double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude * (3.141592653589793 / 180);
    final lat2 = b.latitude * (3.141592653589793 / 180);
    final dLat = (b.latitude - a.latitude) * (3.141592653589793 / 180);
    final dLon = (b.longitude - a.longitude) * (3.141592653589793 / 180);
    final sinDLat = sin(dLat / 2);
    final sinDLon = sin(dLon / 2);
    final h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon;
    return 2 * r * asin(sqrt(h));
  }

  /// Precomputed cumulative distances along _routePoints
  List<double> _buildCumulativeDistances() {
    final distances = <double>[0.0];
    for (int i = 1; i < _routePoints.length; i++) {
      distances.add(
        distances.last + _haversineMeters(_routePoints[i - 1], _routePoints[i]),
      );
    }
    return distances;
  }

  /// Gets the exact LatLng position at [traveledMeters] along the polyline
  LatLng _positionAtDistance(List<double> cumDist, double traveledMeters) {
    if (traveledMeters <= 0) return _routePoints.first;
    if (traveledMeters >= cumDist.last) return _routePoints.last;

    // Binary search for the segment
    int lo = 0, hi = cumDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (cumDist[mid] <= traveledMeters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = cumDist[hi] - cumDist[lo];
    if (segLen == 0) return _routePoints[lo];
    final t = (traveledMeters - cumDist[lo]) / segLen;

    final a = _routePoints[lo];
    final b = _routePoints[hi];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  void _startRouteAnimation({double initialTraveledMeters = 0.0}) {
    if (_isAnimating || _routePoints.length < 2 || !mounted) return;
    setState(() {
      _isAnimating = true;
    });

    final cumDist = _buildCumulativeDistances();
    final totalMeters = cumDist.last;
    final speedMs = _vehicleSpeedMs();

    double traveledMeters = initialTraveledMeters;
    const tickMs = 16; // ~60 fps

    debugPrint('(vehicle: $_vehicleType)');

    _showNextAlert();
    _startAlertRotation();

    _animationTimer = Timer.periodic(const Duration(milliseconds: tickMs), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      traveledMeters += speedMs * (tickMs / 1000.0);
      // Keep _pausedTraveledMeters in sync so STOP saves the right position
      _pausedTraveledMeters = traveledMeters;

      if (traveledMeters >= totalMeters) {
        timer.cancel();
        _isAnimating = false;
        _pausedTraveledMeters = 0.0; // Reset after journey completes
        if (mounted) {
          setState(() {
            _currentPos = _routePoints.last;
            _polylines.clear(); // Destination reached, clear polyline
            _updateMarkersNoSetState();
          });
          _showJourneyCompletedDialog();
        }
        debugPrint('🗺️ Route animation complete.');
        return;
      }

      final nextPoint = _positionAtDistance(cumDist, traveledMeters);

      // Dynamic distance tallying
      final remainingMeters = totalMeters - traveledMeters;
      String distanceStr;
      if (remainingMeters > 1000) {
        distanceStr = "${(remainingMeters / 1000).toStringAsFixed(1)} km";
      } else {
        distanceStr = "${remainingMeters.toStringAsFixed(0)} m";
      }

      // Find which points are ahead of us
      int hi = 0;
      while (hi < cumDist.length && cumDist[hi] <= traveledMeters) {
        hi++;
      }

      final remainingPoints = [nextPoint, ..._routePoints.sublist(hi)];

      setState(() {
        _currentPos = nextPoint;
        _distance = distanceStr; // Tally distance
        _updateMarkersNoSetState();

        // Sync to JourneyService for SOS use
        final js = Provider.of<JourneyService>(context, listen: false);
        js.updateIconPosition(nextPoint);

        // Push live location to Supabase for tracker view
        if (js.activeJourneyId != null) {
          js.updateLiveLocation(js.activeJourneyId!, nextPoint);
        }

        // Dynamically decrease polyline
        _polylines.clear();
        _polylines.add(
          Polyline(
            polylineId: const PolylineId("route"),
            points: remainingPoints,
            color: AppTheme.primaryOrange,
            width: 6,
          ),
        );
      });

      if (_followingUser && _mapController != null) {
        _mapController!.moveCamera(CameraUpdate.newLatLng(nextPoint));
      }

      _checkProximityAlerts();
      _checkStepTrigger(traveledMeters);
    });
  }

  void _calculateStepBoundaries() {
    _stepDistances.clear();
    double currentCumDist = 0.0;
    for (var step in _steps) {
      if (step["distance"] != null && step["distance"]["value"] != null) {
        currentCumDist += step["distance"]["value"].toDouble();
        _stepDistances.add(currentCumDist);
      }
    }
  }

  void _checkStepTrigger(double traveledMeters) {
    debugPrint('🗺️ Travel: ${traveledMeters.toStringAsFixed(1)}m');
    int newStepIdx = -1;
    for (int i = 0; i < _stepDistances.length; i++) {
      if (traveledMeters <= _stepDistances[i]) {
        newStepIdx = i;
        break;
      }
    }

    if (newStepIdx != -1 && newStepIdx != _currentStepIndex) {
      debugPrint('🗺️ Step Changed: $newStepIdx');
      _currentStepIndex = newStepIdx;
      _onStepChanged(_currentStepIndex);
    }
  }

  void _onStepChanged(int idx) {
    if (idx < 0 || idx >= _steps.length) return;
    final step = _steps[idx];
    final String instruction = (step["html_instructions"] ?? "").toLowerCase();
    debugPrint('🗺️ Instruction ($idx): $instruction');

    bool isTurn =
        instruction.contains("left") ||
        instruction.contains("right") ||
        instruction.contains("turn");

    if (isTurn) {
      _navAlertPriorityTimer?.cancel();
      setState(() {
        _isShowingNavAlert = true;
        _currentCategory = "Navigation";
        _alertHeading = step["html_instructions"].replaceAll(
          RegExp(r'<[^>]*>|&[^;]+;'),
          ' ',
        );
        _alertSubtext = "Prepare to turn";
      });

      _speak("$_alertHeading. $_alertSubtext");

      // Keep the nav alert for 7 seconds before allowing safety alerts to resume
      _navAlertPriorityTimer = Timer(const Duration(seconds: 7), () {
        if (mounted) {
          setState(() {
            _isShowingNavAlert = false;
          });
        }
      });
    }
  }

  Future<void> _showJourneyCompletedDialog() async {
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.green),
            SizedBox(width: 12),
            Text('Journey Completed', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'You have reached your destination successfully. Would you like to end the session?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'STAY ON MAP',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final journeyService = Provider.of<JourneyService>(
                context,
                listen: false,
              );
              final authService = Provider.of<AuthService>(
                context,
                listen: false,
              );

              // End journey in DB if we have an ID
              final journeyId = journeyService.activeJourneyId;
              if (journeyId != null) {
                final dbSuccess = await journeyService.endJourney(journeyId);
                if (dbSuccess) {
                  // Update user statistics
                  await authService.updateUserStats(
                    rideIncrement: 1,
                    pointIncrement: 100,
                    scoreAdjustment: 5.0,
                  );
                }
              }

              journeyService.clearActiveJourney();
              if (mounted) {
                Navigator.pop(ctx); // Close dialog
                Navigator.pop(context); // Navigate back to Setup
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryOrange,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('FINISH'),
          ),
        ],
      ),
    );
  }

  /// Updates markers without an extra setState (called inside an existing setState)
  void _updateMarkersNoSetState() {
    final Set<Marker> newMarkers = {};

    if (_currentPos != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('user_pos'),
          position: _currentPos!,
          icon:
              _userIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'You'),
          anchor: const Offset(0.5, 0.5),
          zIndex: 10,
        ),
      );
    }

    if (_startLatLng != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: _startLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      );
    }

    if (_destLatLng != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('dest'),
          position: _destLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      );
    }

    // SOS Markers (Red dots)
    final journeyService = Provider.of<JourneyService>(context, listen: false);
    for (var i = 0; i < journeyService.globalSosEvents.length; i++) {
      final event = journeyService.globalSosEvents[i];
      final pos = LatLng(event['latitude'], event['longitude']);
      final type = event['incident_type'] as String? ?? '';
      final desc = event['incident_description'] as String? ?? '';
      final userName = event['user_name'] as String? ?? 'User';
      final evCreatedAt = event['created_at'] as String? ?? '';

      String displayTitle = 'Incident';
      String dateLine = '';
      try {
        if (evCreatedAt.isNotEmpty) {
          final dt = DateTime.parse(evCreatedAt).toLocal();
          final timeStr = DateFormat('HH:mm').format(dt);
          displayTitle = "From:\n $userName – Incident Alert at $timeStr";
          dateLine = DateFormat('MMMM dd, yyyy').format(dt);
        }
      } catch (e) {}

      String snippet =
          "Reported by $userName: $type\n( $desc )\nDate: $dateLine";

      newMarkers.add(
        Marker(
          markerId: MarkerId('sos_all_$i'),
          position: pos,
          icon:
              _redDotIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(title: displayTitle, snippet: snippet),
          zIndex: 15,
        ),
      );
    }

    _markers.clear();
    _markers.addAll(newMarkers);
  }

  Future<void> _loadAccidentData() async {
    try {
      final String csvData = await rootBundle.loadString(
        'lib/datasets/accidents.csv',
      );
      final List<String> lines = csvData.split('\n');
      if (lines.isEmpty) return;

      final List<String> headers = lines[0].split(',');
      final Map<String, List<Map<String, String>>> grouped = {
        'Good Driving': [],
        'Too Fast': [],
        'Go Slow': [],
        'Obstacles Ahead': [],
        'Caution': [],
      };

      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;

        final values = _parseCsvLine(line);
        if (values.length == headers.length) {
          final Map<String, String> row = {};
          for (int j = 0; j < headers.length; j++) {
            row[headers[j].trim()] = values[j].trim();
          }

          final String category = row['alert_category'] ?? '';
          if (grouped.containsKey(category)) {
            grouped[category]!.add(row);
          }
        }
      }

      setState(() {
        _groupedAlerts = grouped;
      });
    } catch (e) {
      debugPrint("Error loading accident data: $e");
    }

    // First alert is now initialized as "Waiting"
    if (_routeFetched) {
      _alertHeading = "Waiting...";
      _alertSubtext = "Please Start the Journey.";
    }
  }

  List<String> _parseCsvLine(String line) {
    final List<String> result = [];
    bool inQuotes = false;
    StringBuffer currentField = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(currentField.toString());
        currentField.clear();
      } else {
        currentField.write(char);
      }
    }
    result.add(currentField.toString());
    return result;
  }

  void _startAlertRotation() {
    _alertTimer?.cancel();
    _alertTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _showNextAlert();
    });
  }

  void _showNextAlert() {
    if (_groupedAlerts.isEmpty || _isShowingNavAlert) return;

    _totalAlertsShown++;

    // Requirement: Caution every 5th time, otherwise Good Driving
    if (_totalAlertsShown % 5 == 0) {
      _currentCategory = 'Caution';
    } else {
      _currentCategory = 'Good Driving';
    }

    final alertsInCategory = _groupedAlerts[_currentCategory] ?? [];
    if (alertsInCategory.isEmpty) return;

    // Use a simple counter for the current category to cycle through its alerts
    int currentCategoryIndex = 0;
    if (_currentCategory == 'Good Driving') {
      currentCategoryIndex = _totalAlertsShown % alertsInCategory.length;
    } else if (_currentCategory == 'Caution') {
      currentCategoryIndex = _totalAlertsShown % alertsInCategory.length;
    }

    final alert = alertsInCategory[currentCategoryIndex];

    if (mounted) {
      setState(() {
        _alertHeading = alert['alert_message'] ?? 'Stay Safe';
        _alertSubtext = alert['safety_advice'] ?? 'Proceed with caution.';
      });
      _speak("$_alertHeading. $_alertSubtext");
    }
  }

  void _checkProximityAlerts() {
    if (_currentPos == null) return;

    final journeyService = Provider.of<JourneyService>(context, listen: false);
    final events = journeyService.globalSosEvents;

    Map<String, dynamic>? nearestEvent;
    double minDistance = 10; // Precise threshold

    for (var event in events) {
      final double eventLat = (event['latitude'] as num).toDouble();
      final double eventLng = (event['longitude'] as num).toDouble();
      final LatLng eventPos = LatLng(eventLat, eventLng);

      final double distance = _haversineMeters(_currentPos!, eventPos);

      // We only care about events within 2 meters
      if (distance <= 10.0) {
        if (distance < minDistance) {
          minDistance = distance;
          nearestEvent = event;
        }
      }
    }

    if (nearestEvent != null) {
      final String id = nearestEvent['id']?.toString() ?? '';

      // Update active event for UI dismissal logic
      if (_activeSosEvent?['id']?.toString() != id) {
        final Map<String, dynamic> eventData = nearestEvent;
        setState(() {
          _activeSosEvent = eventData;

          // Only trigger audio/heading alert once per incident
          if (id.isNotEmpty && !_triggeredSosIds.contains(id)) {
            _triggeredSosIds.add(id);
            final String type = eventData['incident_type'] ?? 'Incident';
            final String desc =
                eventData['incident_description'] ?? 'Stay careful';
            final String userName = eventData['user_name'] ?? 'Someone';

            _currentCategory = "Caution";
            _alertHeading = "SOS: $type";
            _alertSubtext = "Reported by $userName: $desc. Please be careful.";
            _speak("$_alertHeading. $_alertSubtext");
            debugPrint('🚨 SOS Proximity Alert triggered for $id');
          }
        });
      }
    } else {
      // Clear active event as user icon crosses/leaves the 2m radius
      if (_activeSosEvent != null) {
        setState(() {
          _activeSosEvent = null;
        });
      }
    }
  }

  String _getPositiveKeyword() {
    final keywords = ['Safe Driving', 'Excellent', 'Smooth Ride', 'Great Job'];
    // Iteration 1-4 are positive
    // _totalAlertsShown % 5 results in 1, 2, 3, 4, 0
    // If it's 0, it's Caution (handled by _currentCategory)
    // Otherwise, use 1..4 to index into keywords 0..3
    int idx = (_totalAlertsShown % 5) - 1;
    if (idx < 0) idx = 0; // Fallback
    return keywords[idx % keywords.length];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Live Navigation',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      bottomNavigationBar: const SharedBottomNav(currentRoute: '/map'),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: AppTheme.premiumBackground,
        child: Stack(
          children: [
            // Real Map View
            Consumer<JourneyService>(
              builder: (context, journeyService, child) {
                // Ensure markers are refreshed when SOS points change
                _updateMarkersNoSetState();
                return GoogleMap(
                  initialCameraPosition: _kDelhi,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  zoomControlsEnabled: false,
                  mapType: MapType.normal,
                  polylines: _polylines,
                  markers: _markers,
                  onCameraMove: (position) {
                    if (_followingUser) {}
                  },
                  onMapCreated: (GoogleMapController controller) async {
                    _mapController = controller;
                    final args =
                        ModalRoute.of(context)?.settings.arguments
                            as Map<String, dynamic>?;
                    if (args == null || args['start'] == null) {
                      try {
                        if (!kIsWeb) {
                          final lastPos =
                              await Geolocator.getLastKnownPosition();
                          if (lastPos != null && mounted) {
                            _mapController?.moveCamera(
                              CameraUpdate.newLatLngZoom(
                                LatLng(lastPos.latitude, lastPos.longitude),
                                14.5,
                              ),
                            );
                            setState(() {
                              _currentPos = LatLng(
                                lastPos.latitude,
                                lastPos.longitude,
                              );
                              _updateMarkers();
                            });
                          }
                        }

                        try {
                          final position = await Geolocator.getCurrentPosition(
                            locationSettings: const LocationSettings(
                              accuracy: LocationAccuracy.best,
                            ),
                          ).timeout(const Duration(seconds: 20));

                          if (mounted) {
                            _mapController!.animateCamera(
                              CameraUpdate.newLatLngZoom(
                                LatLng(position.latitude, position.longitude),
                                14.5,
                              ),
                            );
                            setState(() {
                              _currentPos = LatLng(
                                position.latitude,
                                position.longitude,
                              );
                              _followingUser = true;
                              _updateMarkers();
                            });
                          }
                        } catch (e) {
                          debugPrint(
                            "Accuracy follow-up timed out or failed in MapScreen: $e",
                          );
                        }
                      } catch (e) {
                        debugPrint("Initial location error in MapScreen: $e");
                      }
                    } else if (args['start'] != null && args['dest'] != null) {
                      _fitBounds(args['start'], args['dest']);
                    }
                  },
                );
              },
            ),
            SafeArea(
              child: Column(
                children: [
                  // Top Info Card
                  Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppTheme.primaryOrange.withOpacity(0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.trip_origin,
                              color: Colors.green,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _fromAddress,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _toAddress,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white24, height: 16),
                        Row(
                          children: [
                            Icon(
                              Icons.directions,
                              color: AppTheme.accentYellow,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        'Dist: $_distance',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        'Time: $_duration',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      GestureDetector(
                                        onTap: () {
                                          if (_isAnimating) {
                                            // STOP: cancel timers and save current position for resume
                                            _animationTimer?.cancel();
                                            _alertTimer?.cancel();
                                            setState(() {
                                              _isAnimating = false;
                                              _currentCategory = "Stopped";
                                              _alertHeading = "Journey Paused";
                                              _alertSubtext =
                                                  "Hey, you stopped the journey!";
                                              _updateMarkers();
                                            });
                                            _checkProximityAlerts();
                                            _speak(_alertSubtext);
                                          } else {
                                            // DEMO / RESUME: continue from where we stopped
                                            if (_startLatLng != null &&
                                                _destLatLng != null) {
                                              _animationTimer?.cancel();
                                              setState(() {
                                                _isAnimating = false;
                                                _showSteps =
                                                    true; // Auto-show incidents when demo starts
                                              });
                                              _startRouteAnimation(
                                                initialTraveledMeters:
                                                    _pausedTraveledMeters,
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _isAnimating
                                                ? Colors.redAccent
                                                : AppTheme.primaryOrange,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            _isAnimating ? 'STOP' : 'DEMO',
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _instruction,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _showSteps
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                                color: Colors.white,
                              ),
                              onPressed: () =>
                                  setState(() => _showSteps = !_showSteps),
                              tooltip: 'Show/Hide Steps',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // Navigation Controls (Follow Me & My Location)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FloatingActionButton.small(
                          heroTag: 'follow_toggle',
                          onPressed: () {
                            final args =
                                ModalRoute.of(context)?.settings.arguments
                                    as Map<String, dynamic>?;
                            setState(() => _followingUser = !_followingUser);
                            if (_followingUser && args != null) {
                              _fitBounds(args['start'], args['dest']);
                            }
                          },
                          backgroundColor: _followingUser
                              ? AppTheme.primaryOrange
                              : Colors.black87,
                          child: Icon(
                            Icons.navigation,
                            color: _followingUser ? Colors.black : Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        FloatingActionButton.small(
                          heroTag: 'my_location',
                          onPressed: () async {
                            try {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Finding your location...'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }

                              final pos = await Geolocator.getCurrentPosition(
                                locationSettings: const LocationSettings(
                                  accuracy: LocationAccuracy.best,
                                ),
                              ).timeout(const Duration(seconds: 10));

                              if (mounted) {
                                final latLng = LatLng(
                                  pos.latitude,
                                  pos.longitude,
                                );
                                _mapController?.animateCamera(
                                  CameraUpdate.newLatLng(latLng),
                                );
                                setState(() {
                                  _currentPos = latLng;
                                  _followingUser = true;
                                  _updateMarkers();
                                });
                              }
                            } catch (e) {
                              debugPrint(
                                "Manual location fetch failed in MapScreen: $e",
                              );
                              if (!kIsWeb) {
                                final lastPos =
                                    await Geolocator.getLastKnownPosition();
                                if (lastPos != null && mounted) {
                                  final lastLatLng = LatLng(
                                    lastPos.latitude,
                                    lastPos.longitude,
                                  );
                                  _mapController?.animateCamera(
                                    CameraUpdate.newLatLng(lastLatLng),
                                  );
                                  setState(() {
                                    _currentPos = lastLatLng;
                                    _followingUser = true;
                                    _updateMarkers();
                                  });
                                }
                              }
                            }
                          },
                          backgroundColor: Colors.black87,
                          child: const Icon(
                            Icons.my_location,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (!_showSteps)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: FloatingActionButton.extended(
                        onPressed: () => Navigator.pop(context),
                        backgroundColor: Colors.redAccent,
                        extendedPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ), // Slimmer button
                        label: const Text(
                          'END NAVIGATION',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 1.0,
                          ),
                        ),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ),

                  // Info popup panel below END NAVIGATION
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: _showSteps
                        ? Container(
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.42,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(0xFF0F172A).withOpacity(0.98),
                                  const Color(0xFF1E1B4B).withOpacity(0.95),
                                  const Color(0xFF312E81).withOpacity(0.9),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(30),
                              border: Border.all(
                                color: Colors.indigoAccent.withOpacity(0.4),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.indigo.withOpacity(0.4),
                                  blurRadius: 30,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Drag Handle
                                Container(
                                  width: 40,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Flexible(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Top Header Row: Professional Tiles
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 14,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.05,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              22,
                                            ),
                                            border: Border.all(
                                              color: Colors.white10,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceAround,
                                            children: [
                                              _infoTile(
                                                icon: Icons.straighten_rounded,
                                                label: 'DIST',
                                                value: _distance,
                                                color: Colors.greenAccent,
                                              ),
                                              _infoTile(
                                                icon: Icons.timer_rounded,
                                                label: 'TIME',
                                                value: _duration,
                                                color: Colors.cyanAccent,
                                              ),
                                              _infoTile(
                                                icon: Icons.speed_rounded,
                                                label: 'SPEED',
                                                value: (_vehicleSpeedMs() * 3.6)
                                                    .toStringAsFixed(1),
                                                color: Colors.orangeAccent,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        // Alert Container with Glassmorphism
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.05,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                            border: Border.all(
                                              color: Colors.white10,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: SizedBox(
                                                  height: 95,
                                                  child: Scrollbar(
                                                    controller:
                                                        _alertScrollController,
                                                    thumbVisibility: true,
                                                    thickness: 4,
                                                    radius:
                                                        const Radius.circular(
                                                          10,
                                                        ),
                                                    child: SingleChildScrollView(
                                                      controller:
                                                          _alertScrollController,
                                                      padding:
                                                          const EdgeInsets.only(
                                                            right: 16,
                                                          ),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          // Dynamic Badge (Caution or Excellence)
                                                          Wrap(
                                                            crossAxisAlignment:
                                                                WrapCrossAlignment
                                                                    .center,
                                                            children: [
                                                              Container(
                                                                padding:
                                                                    const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          10,
                                                                      vertical:
                                                                          4,
                                                                    ),
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      (_currentCategory ==
                                                                          "Good Driving")
                                                                      ? Colors
                                                                            .green
                                                                            .withOpacity(
                                                                              0.2,
                                                                            )
                                                                      : (_currentCategory ==
                                                                            "Navigation")
                                                                      ? Colors
                                                                            .cyan
                                                                            .withOpacity(
                                                                              0.2,
                                                                            )
                                                                      : Colors
                                                                            .red
                                                                            .withOpacity(
                                                                              0.2,
                                                                            ),
                                                                  border: Border.all(
                                                                    color:
                                                                        (_currentCategory ==
                                                                            "Good Driving")
                                                                        ? Colors
                                                                              .greenAccent
                                                                        : (_currentCategory ==
                                                                              "Navigation")
                                                                        ? Colors
                                                                              .cyanAccent
                                                                        : Colors
                                                                              .redAccent,
                                                                    width: 1.5,
                                                                  ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        10,
                                                                      ),
                                                                  boxShadow: [
                                                                    BoxShadow(
                                                                      color:
                                                                          (_currentCategory ==
                                                                              "Good Driving")
                                                                          ? Colors.green.withOpacity(
                                                                              0.3,
                                                                            )
                                                                          : (_currentCategory ==
                                                                                "Navigation")
                                                                          ? Colors.cyan.withOpacity(
                                                                              0.3,
                                                                            )
                                                                          : Colors.red.withOpacity(
                                                                              0.3,
                                                                            ),
                                                                      blurRadius:
                                                                          8,
                                                                    ),
                                                                  ],
                                                                ),
                                                                child: Text(
                                                                  (!_isAnimating &&
                                                                          _totalAlertsShown ==
                                                                              0)
                                                                      ? 'Waiting'
                                                                      : (_currentCategory ==
                                                                            "Caution")
                                                                      ? 'Caution'
                                                                      : (_currentCategory ==
                                                                            "Navigation")
                                                                      ? 'Turn Alert'
                                                                      : (_currentCategory ==
                                                                            "Stopped")
                                                                      ? 'Status'
                                                                      : _getPositiveKeyword(),
                                                                  style: TextStyle(
                                                                    color:
                                                                        (_currentCategory ==
                                                                            "Good Driving")
                                                                        ? Colors
                                                                              .greenAccent
                                                                        : (_currentCategory ==
                                                                              "Navigation")
                                                                        ? Colors
                                                                              .cyanAccent
                                                                        : Colors
                                                                              .redAccent,
                                                                    fontSize:
                                                                        11,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    letterSpacing:
                                                                        0.5,
                                                                  ),
                                                                ),
                                                              ),
                                                              const Padding(
                                                                padding:
                                                                    EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          8,
                                                                    ),
                                                                child: Text(
                                                                  ':',
                                                                  style: TextStyle(
                                                                    color: Colors
                                                                        .white70,
                                                                  ),
                                                                ),
                                                              ),
                                                              Text(
                                                                _alertHeading,
                                                                style: const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                  fontSize: 16,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            (!_isAnimating &&
                                                                    _totalAlertsShown ==
                                                                        0)
                                                                ? 'Waiting...'
                                                                : (_currentCategory ==
                                                                      "Navigation")
                                                                ? 'Navigation'
                                                                : (_currentCategory ==
                                                                      "Stopped")
                                                                ? 'Paused'
                                                                : (_currentCategory ==
                                                                      "Good Driving")
                                                                ? 'Keep going!'
                                                                : 'Go, slow.',
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 24,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w900,
                                                                  letterSpacing:
                                                                      -0.5,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 8,
                                                          ),
                                                          RichText(
                                                            text: TextSpan(
                                                              style:
                                                                  const TextStyle(
                                                                    color: Colors
                                                                        .white70,
                                                                    fontSize:
                                                                        14,
                                                                    height: 1.4,
                                                                  ),
                                                              children: [
                                                                const TextSpan(
                                                                  text:
                                                                      'Status: ',
                                                                  style: TextStyle(
                                                                    color: Colors
                                                                        .white38,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w300,
                                                                  ),
                                                                ),
                                                                TextSpan(
                                                                  text: _alertSubtext
                                                                      .replaceAll(
                                                                        'Caution suggested near ',
                                                                        '',
                                                                      )
                                                                      .replaceAll(
                                                                        'Caution suggested near',
                                                                        '',
                                                                      ),
                                                                  style: const TextStyle(
                                                                    color: Colors
                                                                        .white,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        // Incidents Section
                                        const Align(
                                          alignment: Alignment.centerLeft,
                                          child: Padding(
                                            padding: EdgeInsets.only(left: 8),
                                            child: Text(
                                              'INCIDENTS',
                                              style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Container(
                                          height: 200,
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.03,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                            border: Border.all(
                                              color: Colors.white10,
                                            ),
                                          ),
                                          child: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 500,
                                            ),
                                            transitionBuilder:
                                                (
                                                  Widget child,
                                                  Animation<double> animation,
                                                ) {
                                                  return FadeTransition(
                                                    opacity: animation,
                                                    child: SlideTransition(
                                                      position: Tween<Offset>(
                                                        begin: const Offset(
                                                          0.0,
                                                          0.1,
                                                        ),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: child,
                                                    ),
                                                  );
                                                },
                                            child: _buildCurrentIncident(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                IconButton(
                                  icon: const Icon(
                                    Icons.keyboard_arrow_up_rounded,
                                    color: Colors.white30,
                                    size: 24,
                                  ),
                                  onPressed: () =>
                                      setState(() => _showSteps = false),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentIncident() {
    if (_activeSosEvent == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.radar_rounded,
              color: Colors.indigoAccent.withOpacity(0.3),
              size: 40,
            ),
            const SizedBox(height: 12),
            const Text(
              'Scanning for nearby incidents...',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    final event = _activeSosEvent!;
    final String type = event['incident_type'] ?? 'Incident';
    final String description = event['incident_description'] ?? 'Stay careful';
    final String userName = event['user_name'] ?? 'Someone';
    final String createdAt = event['created_at']?.toString() ?? '';

    String timeStr = 'Recently';
    try {
      if (createdAt.isNotEmpty) {
        final dt = DateTime.parse(createdAt).toLocal();
        timeStr = DateFormat('HH:mm').format(dt);
      }
    } catch (e) {}

    Color incidentColor = Colors.redAccent;
    IconData incidentIcon = Icons.warning_rounded;

    return Container(
      key: ValueKey<String>(event['id']?.toString() ?? 'sos'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: incidentColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: incidentColor.withOpacity(0.3),
                    width: 1.5,
                  ),
                ),
                child: Icon(incidentIcon, color: incidentColor, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "LIVE SOS ALERT ($timeStr)",
                    style: TextStyle(
                      color: incidentColor,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Text(
                    "REPORTED BY $userName",
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "$type: $description",
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blueAccent.withOpacity(0.2)),
            ),
            child: const Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_rounded,
                      color: Colors.blueAccent,
                      size: 14,
                    ),
                    SizedBox(width: 6),
                    Text(
                      "DRIVING ADVICE",
                      style: TextStyle(
                        color: Colors.blueAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Text(
                  "Approach this area with extreme caution. Watch for emergency vehicles.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Container(
          width: 34, // reduced from 38
          height: 34,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 18), // reduced from 20
        ),
        const SizedBox(height: 4), // reduced from 6
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 13, // reduced from 14
          ),
        ),
        const SizedBox(height: 1), // reduced from 2
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9, // reduced from 10
          ),
        ),
      ],
    );
  }
}
