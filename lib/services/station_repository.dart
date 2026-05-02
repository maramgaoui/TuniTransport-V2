import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/station_model.dart';

class StationMatch {
  final Station station;
  final double score;

  const StationMatch({required this.station, required this.score});
}

class StationDistance {
  final Station station;
  final double distanceKm;

  const StationDistance({required this.station, required this.distanceKm});
}

class StationRepository {
  final FirebaseFirestore _firestore;

  // ── In-memory station cache (H-1 fix) ──────────────────────────────────
  static List<Station>? _cachedStations;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheTtl = Duration(minutes: 10);

  static void invalidateCache() {
    _cachedStations = null;
    _cacheTimestamp = null;
  }

  static const Map<String, List<String>> _stationAliasesById = {
    'bs_tunis_ville': ['tunis', 'gare de tunis', 'tunis gare', 'tunis centrale'],
    'rd_saida_manoubia': ['saida manoubia', 'sayda manoubia', 'manoubia'],
    'bs_ezzahra': ['ez zahra', 'ez-zahra', 'ezzahra banlieue'],
    'bs_lycee_ezzahra': ['lycee ez zahra', 'lycee ez-zahra'],
    'bs_hammam_echatt': ['hammam chott', 'hammam echatt'],
    'bs_megrine_riadh': ['megrine riadh', 'mégrine riadh'],
    'bs_megrine': ['megrine', 'mégrine'],
    'bs_erriadh': ['erriadh', 'riadh'],
    'bs_rades': ['rades', 'rades ville'],
    'bs_lycee_rades': ['lycee rades'],
    'bs_arret_stade': ['arret stade', 'stade hammam lif'],
    'ms_aeroport': ['aeroport', 'airport', 'aeroport skanes monastir', 'l aeroport'],
    'ms_sousse_bab_jedid': ['sousse', 'sousse bab jedid', 'gare sousse', 'sousse centre'],
    'ms_monastir': ['monastir', 'monastir centre'],
    'ms_sousse_zi': ['sousse zi', 'sousse zone industrielle'],
    'ms_monastir_zi': ['monastir zi', 'monastir zone industrielle'],
    'ms_teboulba_zi': ['teboulba zi', 'teboulba zone industrielle'],
    'ms_moknine_zi': ['moknine zi', 'moknine zone industrielle'],
    'ms_ksar_hellal_zi': ['ksar hellal zi', 'ksar hellal zone industrielle'],
    'rd_gobaa_ville': ['gobaa ville', 'la gobaa'],
    // SNCFT mainline
    'sncft_sousse_voyageurs': ['sousse voyageurs', 'sousse gare', 'gare de sousse'],
    'sncft_sfax':             ['sfax gare', 'gare de sfax'],
    'sncft_gabes':            ['gabes gare', 'gare de gabes', 'gabès'],
    'sncft_gafsa':            ['gafsa gare'],
    'sncft_tozeur':           ['tozeur gare'],
    'sncft_bir_bou_regba':    ['bir bou regba', 'b.b. regba', 'bb regba'],
    'sncft_grombalia':        ['grombalia'],
    'sncft_enfidha':          ['enfidha'],
    'sncft_el_jem':           ['el jem', 'el djem'],
    'sncft_mahares':          ['mahares', 'maharès'],
    'sncft_ghraiba':          ['ghraiba', 'ghraïba'],
    'sncft_metlaoui':         ['metlaoui'],
    // SNCFT Kef / Kalaa Khasba
    'sncft_kef_le_kef':       ['le kef', 'kef', 'gare du kef'],
    'sncft_kef_dahmani':      ['dahmani'],
    'sncft_kef_gaafour':      ['gaafour', 'gafour'],
    'sncft_kef_kalaa_khasba': ['kalaa khasba', 'kalaa khesba', 'ksar'],
    // Banlieue de Nabeul (official SNCFT timetable - 13 stations)
    'bn_tunis':               ['tunis', 'tunis banlieue', 'gare de tunis'],
    'bn_borj_cedria':         ['borj cedria', 'borj cedria banlieue'],
    'bn_foundouk_jedid':      ['foundouk jedid', 'fondouk jedid'],
    'bn_khanguet':            ['khanguet', 'khanquet'],
    'bn_grombalia':           ['grombalia', 'qrombalia'],
    'bn_turki':               ['turki', 'sidi turki'],
    'bn_belli':               ['belli', 'sidi belli'],
    'bn_bou_arkoub':          ['bou arkoub', 'boua rkoub'],
    'bn_bir_bou_regba':       ['bir bou regba', 'bir bou r gba', 'bir bouregba'],
    'bn_hammamet':            ['hammamet', 'hammament', 'hammamet banlieue'],
    'bn_omar_khayem':         ['omar khayem', 'omar khayam', 'khayem', 'khayam', 'nabeul'],
    'bn_mrazga':              ['m\'razga', 'mrazga', 'meraqua'],
    'bn_nabeul':              ['nabeul', 'nabel', 'gare de nabeul', 'nabeul gare'],
    // TRANSTU Bus Hubs
    'transtu_hub_tunis_marine':  ['tunis marine', 'marine', 'bus tunis'],
    'transtu_hub_barcelone':     ['barcelone', 'place barcelone'],
    'transtu_hub_jardin_thameur':['jardin thameur', 'thameur', 'hadika thameur', 'جنينة ثامر'],
    'transtu_hub_bab_alioua':    ['bab alioua', 'bab aliwa'],
    'transtu_hub_ariana':        ['ariana', 'ariana bus'],
    'transtu_hub_carthage':      ['carthage', 'carthage bus'],
    'transtu_hub_charguia':      ['charguia', 'charguia bus', 'sharqiya', 'el charguia', 'la charguia'],
    'transtu_hub_intilaka':      ['intilaka', 'intileka', 'intilaqa', 'انطلاقة'],
    'transtu_hub_bellevue':      ['bellevue', 'bellevie', 'belle vue', 'belvédère', 'belvedere'],
    'transtu_hub_bel_houan':     ['ali belhouan', 'bel houan', 'belhouan', 'belhouane', 'علي بلهوان'],
    'transtu_hub_kabaa':         ['kabaa', 'قباعة'],
    'transtu_hub_khaireddine':   ['kheireddine', 'khaireddine', 'khaireddin', 'kheredine'],
    'transtu_hub_montazah':      ['montazah', 'montazeh', 'منتزه'],
    'transtu_hub_morneg':               ['mornag', 'morneg', 'مرناق'],
    'transtu_hub_10_decembre':          ['10 decembre', 'dix decembre'],
    'transtu_hub_slimlen_kahia':        ['slimane kahia', 'slim kahia', 'slimlen kahia', 'سليمان كاهية'],
    'transtu_hub_tbourba':              ['tebourba', 'tbourba', 'طبربة'],
    // Hubs from official TRANSTU open data (not in legacy data)
    'transtu_hub_gare_routiere_sud':    ['gare routiere sud', 'gare sud', 'bab el khadra', 'باب الخضراء'],
    'transtu_hub_hopital_des_enfants':  ['hopital des enfants', 'hospital des enfants', 'مستشفى الأطفال'],
    'transtu_hub_mourouj_5':            ['mourouj 5', 'el mourouj 5', 'المروج 5'],
    'transtu_hub_mourouj_2':            ['mourouj 2', 'el mourouj 2', 'المروج 2', 'rabattement mourouj'],
    // TRANSTU intermediate stops (10 Décembre lines)
    'transtu_stop_ariana_centre':  ['ariana centre', 'centre ariana'],
    'transtu_stop_ghazala_techno': ['technopole ghazala', 'el ghazala tech', 'technopole'],
    'transtu_stop_ghazala_cite':   ['cite ghazala', 'cite el ghazala', 'ghazala'],
    'transtu_stop_aeroport':       ['aeroport', 'aeroport tunis', 'tunis carthage aeroport'],
    'transtu_stop_goulette':       ['goulette', 'la goulette', 'goulette casino'],
    // TRANSTU neighbourhood stops (search targets → redirect to hub)
    // These appear as "arrival" when user searches from a hub.
    // They do NOT need to be real Firestore station docs unless you want
    // them to appear as departure options too.
    
    // Barcelone hub destinations (for filtering)
    'transtu_dest_medina_jdida':        ['medina jdida', 'madina jdida', 'المدينة الجديدة'],
    'transtu_dest_hay_thameur':         ['hay thameur', 'cité thameur', 'cite thameur', 'حي ثامر'],
    'transtu_dest_mornag':              ['mornag', 'مرناق', 'mrornag'],
    'transtu_dest_ben_arous':           ['ben arous', 'benarous', 'بن عروس'],
    'transtu_dest_yasminettes':         ['yasminettes', 'les yasminettes', 'الياسمينات', 'jasminate'],
    'transtu_dest_ibn_sina':            ['ibn sina', 'ibnsina', 'ابن سينا'],
    'transtu_dest_boumhal':             ['boumhal', 'boumhel', 'bou mhal', 'بومهل'],
    'transtu_dest_boumhal_gp1':         ['boumhal gp1', 'boumhel gp1', 'boumhal via gp1', 'بومهل عبر الوطنية 1'],
    'transtu_dest_port_rades':          ['port de rades', 'port rades', 'ميناء رادس', 'mina rades'],
    'transtu_dest_megrine_coteau':      ['megrine coteau', 'megrine coteaux', 'مقرين كوطو', 'مقرين'],
    'transtu_dest_megrine_chaker':      ['megrine chaker', 'mégrine chaker', 'مقرين شاكر', 'chaker'],
    'transtu_dest_nouvelle_medina_1':   ['nouvelle medina 1', 'medina jdida 1', 'مدينة جديدة 1', 'المدينة الجديدة 1'],
    'transtu_dest_nouvelle_medina_123': ['nouvelle medina 123', 'medina jdida 123', 'مدينة جديدة 123', 'المدينة الجديدة 123'],
    'transtu_dest_rades_foret':         ['rades foret', 'rades foret', 'رادس الغابة', 'radès forêt'],
    'transtu_dest_el_mourouj_1':        ['el mourouj 1', 'mourouj 1', 'المروج 1', 'morouj 1'],
    'transtu_dest_jaama_el_houda':      ['jaama el houda', 'jamaa el houda', 'جامع الهدى', 'village moyenne', 'جامع الهدى القرية المتوسطية'],
    'transtu_dest_belvedere':           ['belvedere', 'belvédère', 'بلفي'],
    // 10 Décembre hub destinations
    'transtu_dest_sidi_sofiane':   ['sidi sofiane', 'سيدي سفيان'],
    'transtu_dest_cité_mellaha':   ['cite mellaha', 'cité mellaha', 'mellaha', 'حي الملاحة'],
    'transtu_dest_ghazala':        ['ghazala', 'cité ghazala', 'el ghazala', 'غزالة', 'حي الغزالة'],
    'transtu_dest_raoued':         ['raoued', 'raoued plage', 'رواد', 'رواد الشاطئ'],
    'transtu_dest_kalaat_andalous':['kalaat el andalous', 'kalaat andalous', 'qalaat andalous', 'قلعة الأندلس'],
    'transtu_dest_sidi_omar':      ['sidi omar', 'سيدي عمر'],
    'transtu_dest_el_brarjia':     ['el brarjia', 'brarjia', 'البرارجة'],
    'transtu_dest_ariana_brarjia': ['ariana brarjia', 'ariana el brarjia', 'أريانة البرارجة'],
    'transtu_dest_la_goulette':    ['la goulette', 'goulette', 'halq el oued', 'حلق الوادي'],
    'transtu_dest_cité_bakri':     ['cite bakri', 'cité bakri', 'bakri', 'حي البكري'],
    'transtu_dest_nour_jafar':     ['nour jafar', 'jafar', 'نور جعفر'],
    
    // Ariana hub destinations  
    'transtu_dest_manji_salim':    ['manji salim', 'cité manji salim', 'cite manji', 'حي منجي سليم', 'mongi slim', 'cite mongi slim', 'cité mongi slim'],
    'transtu_dest_sidi_salah':     ['sidi salah', 'سيدي صالح'],
    'transtu_dest_menzah9':        ['menzah 9', 'menzah9', 'منزه 9', 'المنتزه 9', 'el menzah 9'],
    'transtu_dest_manouba':        ['manouba', 'mannouba', 'منوبة', 'la manouba'],

    // Bellevue hub destinations
    'transtu_dest_centre_capitale_moh5':   ['centre capitale via mohamed 5', 'centre ville mohamed 5', 'mohamed 5', 'mohammed v', 'cercle centre capitale', 'cercle centre ville via mohamed 5', 'daiiri mohamed 5', 'دائري محمد 5', 'دائري وسط العاصمة عبر محمد 5'],
    'transtu_dest_centre_capitale_9avril': ['centre capitale via 9 avril', 'centre ville 9 avril', '9 avril', 'cercle centre capitale 9 avril', 'cercle centre ville via 9 avril', 'دائري 9 أفريل', 'دائري وسط العاصمة عبر 9 أفريل'],
    'transtu_dest_salambo':                ['salambo', 'salammbo', 'salammbô', 'صلامبو', 'salmbo'],

    // Carthage hub destinations
    'transtu_dest_souk_merkezi':        ['marche central', 'marché central', 'souk central', 'souk merkezi', 'السوق المركزي'],
    'transtu_dest_farch_enneyebi':      ['fouchana', 'frech ennabi', 'farch enneyebi', 'فرش العنابي'],
    'transtu_dest_cite_riadh':          ['cite riadh', 'cité riadh', 'حي الرياض'],
    'transtu_dest_bornaz_jedid2':       ['bir jdid 2', 'bir jedid 2', 'bornaz jedid 2', 'بئر الجديد 2'],
    'transtu_dest_naasan1':             ['naassen 1', 'naasan 1', 'نعسان 1'],
    'transtu_dest_cite_salam':          ['cite essalem', 'cité essalem', 'حي السلام'],
    'transtu_dest_moustawdaa_zahrouni': ['depot zahrouni', 'dépôt zahrouni', 'zahrouni', 'مستودع الزهروني'],

    // Khaireddine hub destinations
    'transtu_dest_cite_el_warda':    ['cite el warda', 'cité wouroud 2', 'cite wouroud', 'حي الوردة 2'],
    'transtu_dest_sanhaja':          ['sanhaja', 'صنهاجة'],
    'transtu_dest_el_kabaa':         ['kabaa', 'kebaâ', 'el kabaa', 'قباعة', 'la kabaa'],
    'transtu_dest_cite_en_nassim':   ['cite nassim', 'cité nassim', 'hay nassim', 'حي النسيم'],
    'transtu_dest_jellou':           ['jellou', 'jelou', 'jallou', 'جلو'],

    // Tunis Marine hub destinations
    'transtu_dest_charguia':                      ['charguia', 'el charguia', 'la charguia', 'الشرقية'],
    'transtu_dest_menzah6':                       ['menzah 6', 'menzah6', 'el menzah 6', 'المنزه 6'],
    'transtu_dest_cite_nasr':                     ['hay ennasr', 'cite ennasr', 'cité ennasr', 'حي النصر'],
    'transtu_dest_lacs_kram':                     ['berges du lac', 'kram', 'le kram', 'lacs kram', 'el bahira el karam', 'البحيرة', 'المرسى'],
    'transtu_dest_marsa':                         ['el marsa', 'la marsa', 'marsa', 'المرسى'],
    'transtu_dest_aeroport':                      ['aeroport', 'airport', 'aéroport', 'المطار'],
    'transtu_dest_jebel_ahmar':                   ['jebel ahmar', 'djebel el ahmar', 'جبل الأحمر'],
    'transtu_dest_10_decembre':                   ['10 decembre', '10 décembre', 'dix decembre', '10 ديسمبر'],
    'transtu_dest_ministere_affaires_etrangeres': ['ministere affaires etrangeres', 'ministère affaires étrangères', 'mae', 'وزارة الخارجية'],
    'transtu_dest_omrane_superieur':              ['omrane superieur', 'el omrane superieur', 'العمران الأعلى'],
    'transtu_dest_jardins_menzah':                ['jardins menzah', 'jardins menzeh', 'hadayek menzah', 'حدائق المنزه'],
    'transtu_dest_ministere_sante':               ['ministere sante', 'ministère santé', 'وزارة الصحة'],
    'transtu_dest_rabta':                         ['ennahla rabta', 'rabta', 'الرابطة', 'ennahla'],
    'transtu_dest_intilaka':                      ['intilaka', 'intileka', 'انطلاقة', 'el intilaka'],
    'transtu_dest_kalaa_jafar':                   ['karyet jaafer', 'karyet jaafar', 'karya jafar', 'قرية جعفر'],
    'transtu_dest_univ_manouba':                  ['universite manouba', 'université manouba', 'univ manouba', 'جامعة منوبة'],
    'transtu_dest_sidi_bou_said':                 ['sidi bou said', 'sidi bousaid', 'سيدي بوسعيد'],
    'transtu_dest_sidi_salah_ettabaa':            ['sidi salah saheb ettabaa', 'sidi salah ettabaa', 'ساحة سلا', 'saheb ettabaa'],

    // Tbourba hub destinations
    'transtu_dest_zone_industrielle': ['zone industrielle manouba', 'zi manouba', 'المنطقة الصناعية منوبة'],
    'transtu_dest_borj_toumi':        ['borj toumi', 'برج التومي'],
    'transtu_dest_edkhila':           ['eddekhila', 'edkhila', 'dakhla', 'الدخيلة'],

    // Ali Belhouane hub destinations
    'transtu_dest_ksar_said2':       ['ksar said 2', 'ksar saïd 2', 'قصر سعيد 2'],
    'transtu_dest_tadhamon':         ['tadhamon', 'ettadhamen', 'lycee ettadhamen', 'حي التضامن', 'معهد حي التضامن'],
    'transtu_dest_cite_bassatine':   ['cite bassatine', 'cité bassatine', 'حي البساتين'],
    'transtu_dest_habibiya2':        ['habibia 2', 'habibiya 2', 'الحبيبية 2'],
    'transtu_dest_cite_wouroud2':    ['cite el ouarda 2', 'cité wouroud 2', 'حي الوردة 2'],
    'transtu_dest_jelou':            ['jelou', 'jallou', 'جلو'],
    'transtu_dest_cite_tahrir':      ['cite ettahrir', 'cité ettahrir', 'حي التحرير'],
    'transtu_dest_qantarat_bizert':  ['pont de bizerte', 'qantarat bizert', 'قنطرة بنزرت'],
    'transtu_dest_bach_hambia':      ['tebourba', 'tbourba', 'طبربة'],
    'transtu_dest_chorfech':         ['chorfech', 'chorfeche', 'شرفش'],
    'transtu_dest_tabria':           ['tabria', 'طابرية'],
    'transtu_dest_mansoura':         ['mansoura', 'منصورة'],
    'transtu_dest_zouitina':         ['zouitina', 'الزويتينة'],
    'transtu_dest_douar_hicher':     ['douar hicher', 'دوار هيشر'],
    'transtu_dest_khaled_ben_walid': ['cite khaled walid', 'cité khaled ibn walid', 'حي خالد ابن الوليد'],
    'transtu_dest_cite_18janvier':   ['cite 18 janvier', 'cité 18 janvier', 'حي 18 جانفي'],
  };

    StationRepository(this._firestore);

  bool isMetroSahelStation(Station station) {
    return station.operatorsHere.contains('sncft_sahel');
  }

  bool isBanlieueSudStation(Station station) {
    return station.operatorsHere.contains('sncft_banlieue_sud');
  }

  bool isBanlieueDStation(Station station) {
    return station.operatorsHere.contains('sncft_banlieue_d');
  }

  bool isBanlieueEStation(Station station) {
    return station.operatorsHere.contains('sncft_banlieue_e');
  }

  bool isTranstuStation(Station station) {
    return station.operatorsHere.contains('transtu');
  }

  bool isBanlieueNabeulStation(Station station) {
    return station.operatorsHere.contains('sncft_banlieue_nabeul');
  }

  bool isSncftMainlineStation(Station station) {
    if (station.id.startsWith('sncft_')) return true;
    return station.operatorsHere.contains('sncft_grandes_lignes');
  }

  bool isStsSahelStation(Station station) {
    return station.operatorsHere.contains('sts_sahel');
  }

  Future<List<Station>> getAllStations({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedStations != null &&
        _cacheTimestamp != null &&
        DateTime.now().difference(_cacheTimestamp!) < _cacheTtl) {
      return _cachedStations!;
    }

    final snapshot = await _firestore.collection('stations').get();
    final stations = snapshot.docs.map((doc) => Station.fromFirestore(doc)).toList();

    // Inject synthetic Station entries for taxi-collectif-only cities.
    // A city is skipped if ANY real station already has the same cityId (e.g.
    // "sousse" covers ms_sousse, sncft_sousse_voyageurs, etc.) or the same
    // normalized name. This prevents synthetic entries from shadowing real
    // stations that serve metro/train/bus on the same city.
    try {
      final taxiSnapshot = await _firestore.collection('taxi_collectif_routes').get();
      final existingCityIds = <String>{
        for (final s in stations) s.cityId.toLowerCase().trim(),
      };
      final existingNames = <String>{
        for (final s in stations) normalizeStationText(s.name),
      };
      final seenCityIds = <String>{};
      for (final doc in taxiSnapshot.docs) {
        final data = doc.data();
        for (final pair in [
          (id: (data['fromCityId'] ?? '') as String, name: (data['fromCityName'] ?? '') as String, nameAr: data['fromCityNameAr'] as String?),
          (id: (data['toCityId'] ?? '') as String, name: (data['toCityName'] ?? '') as String, nameAr: data['toCityNameAr'] as String?),
        ]) {
          if (pair.id.isEmpty || pair.name.isEmpty) continue;
          if (!seenCityIds.add(pair.id)) continue;
          // Skip if a real station already covers this city.
          if (existingCityIds.contains(pair.id.toLowerCase())) continue;
          if (existingNames.contains(normalizeStationText(pair.name))) continue;
          stations.add(Station(
            id: 'tc_city_${pair.id}',
            name: pair.name,
            nameAr: pair.nameAr,
            cityId: pair.id,
            latitude: 0.0,
            longitude: 0.0,
            transportTypes: const ['taxi'],
            operatorsHere: const ['taxi_collectif'],
            createdAt: DateTime(2024),
          ));
        }
      }
    } catch (_) {
      // Best-effort; don't break station list if taxi routes fetch fails.
    }

    _cachedStations = stations;
    _cacheTimestamp = DateTime.now();
    return _cachedStations!;
  }

  Future<List<Station>> searchStationsByName(String query) async {
    if (query.trim().isEmpty) return [];

    final trimmed = query.trim();
    final titleCase = trimmed.isEmpty
        ? trimmed
        : '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';

    final candidateIds = <String>{};

    Future<void> collectPrefix(String q) async {
      if (q.isEmpty) return;
      final snapshot = await _firestore
          .collection('stations')
          .where('name', isGreaterThanOrEqualTo: q)
          .where('name', isLessThanOrEqualTo: '$q\uf8ff')
          .limit(20)
          .get();
      for (final doc in snapshot.docs) {
        candidateIds.add(doc.id);
      }
    }

    await collectPrefix(trimmed);
    if (titleCase != trimmed) {
      await collectPrefix(titleCase);
    }

    final allStations = await getAllStations();
    final ranked = rankStations(query: query, stations: allStations, limit: 8);

    final merged = <Station>[];
    for (final id in candidateIds) {
      final station = allStations.where((s) => s.id == id).cast<Station?>().firstWhere(
            (s) => s != null,
            orElse: () => null,
          );
      if (station != null) merged.add(station);
    }

    for (final match in ranked) {
      if (!merged.any((s) => s.id == match.station.id)) {
        merged.add(match.station);
      }
    }

    final finalRanked = rankStations(query: query, stations: merged, limit: 8);
    return finalRanked.map((m) => m.station).toList();
  }

  List<StationMatch> rankStations({
    required String query,
    required List<Station> stations,
    int limit = 8,
  }) {
    final q = normalizeStationText(query);
    if (q.isEmpty) return const [];

    final queryTokens = q.split(' ').where((t) => t.isNotEmpty).toList();
    final matches = <StationMatch>[];

    for (final station in stations) {
      final normalizedName = normalizeStationText(station.name);
      final normalizedCity = normalizeStationText(station.cityId);
      final aliases = _normalizedAliasesForStation(station);
      final aliasSearch = aliases.join(' ');
      final searchable = '$normalizedName $normalizedCity $aliasSearch'.trim();
      if (searchable.isEmpty) continue;

      var score = 0.0;

      if (normalizedName == q) {
        score = 1.0;
      } else if (searchable == q) {
        score = 1.0;
      } else if (aliases.contains(q)) {
        // Exact alias match (e.g. "sousse" → ms_sousse_bab_jedid) ranks as
        // high as a direct name match so the hub station always wins.
        score = 1.0;
      } else {
        if (searchable.startsWith(q)) {
          score = score > 0.95 ? score : 0.95;
        }
        if (normalizedName.contains(q)) {
          score = score > 0.88 ? score : 0.88;
        }

        final stationTokens = searchable.split(' ').where((t) => t.isNotEmpty).toList();
        final matchedTokens = queryTokens
            .where((qt) => stationTokens.any((st) => st.startsWith(qt) || st.contains(qt)))
            .length;
        if (queryTokens.isNotEmpty) {
          final tokenCoverage = matchedTokens / queryTokens.length;
          if (tokenCoverage > 0) {
            final tokenScore = 0.55 + tokenCoverage * 0.35;
            score = score > tokenScore ? score : tokenScore;
          }
        }

        final similarity = _stringSimilarity(q, normalizedName);
        if (similarity >= 0.58) {
          final fuzzyScore = 0.45 + similarity * 0.45;
          score = score > fuzzyScore ? score : fuzzyScore;
        }

        // Prefer cleaner exact-name intent over compound-name matches.
        final nameTokens =
            normalizedName.split(' ').where((t) => t.isNotEmpty).toList();
        if (queryTokens.isNotEmpty && nameTokens.isNotEmpty) {
          final matchedNameTokens = queryTokens
              .where(
                (qt) =>
                    nameTokens.any((nt) => nt == qt || nt.startsWith(qt)),
              )
              .length;
          if (matchedNameTokens > 0) {
            final tokenPrecision = matchedNameTokens / nameTokens.length;
            final precisionBoost = 0.70 + tokenPrecision * 0.20;
            score = score > precisionBoost ? score : precisionBoost;
          }
        }
      }

      // Synthetic taxi-collectif cities are a last resort — penalise them so
      // real stations always rank above them when both match a query equally.
      if (station.id.startsWith('tc_city_')) score *= 0.6;

      if (score > 0.5) {
        matches.add(StationMatch(station: station, score: score));
      }
    }

    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byHub = (b.station.isMainHub ? 1 : 0).compareTo(a.station.isMainHub ? 1 : 0);
      if (byHub != 0) return byHub;
      return a.station.name.compareTo(b.station.name);
    });

    // Deduplicate by (name, cityId) — same physical station can exist under
    // multiple network IDs (e.g. ms_bekalta and sts_bekalta). Keep highest score.
    final seen = <String>{};
    final deduped = <StationMatch>[];
    for (final m in matches) {
      final key = '${m.station.name.toLowerCase()}|${m.station.cityId}';
      if (seen.add(key)) deduped.add(m);
    }

    return deduped.take(limit).toList();
  }

  Future<List<StationDistance>> findNearestStations({
    required double latitude,
    required double longitude,
    int limit = 3,
  }) async {
    final stations = await getAllStations();
    final candidates = stations
        .where((s) =>
            isMetroSahelStation(s) ||
            isBanlieueSudStation(s) ||
            isBanlieueDStation(s) ||
            isBanlieueEStation(s) ||
            isBanlieueNabeulStation(s) ||
            isSncftMainlineStation(s) ||
            isStsSahelStation(s) ||
            isTranstuStation(s))
        .map((s) => StationDistance(
              station: s,
              distanceKm: s.distanceToCoordinates(latitude, longitude),
            ))
        .toList();

    candidates.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return candidates.take(limit).toList();
  }

  Future<Station?> getStationById(String id) async {
    // Synthetic taxi-collectif city IDs (tc_city_*) are not Firestore docs.
    // Reconstruct the Station from the ID so the controller can proceed.
    if (id.startsWith('tc_city_')) {
      final cityId = id.substring('tc_city_'.length);
      // Convert cityId back to a display name: underscores → spaces, title-case.
      final name = cityId
          .split('_')
          .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
      return Station(
        id: id,
        name: name,
        cityId: cityId,
        latitude: 0.0,
        longitude: 0.0,
        transportTypes: const ['taxi'],
        operatorsHere: const ['taxi_collectif'],
        createdAt: DateTime(2024),
      );
    }
    final doc = await _firestore.collection('stations').doc(id).get();
    return doc.exists ? Station.fromFirestore(doc) : null;
  }

  static String normalizeStationText(String input) {
    var text = input.trim().toLowerCase();
    if (text.isEmpty) return text;

    const replacements = {
      'à': 'a',
      'â': 'a',
      'ä': 'a',
      'é': 'e',
      'è': 'e',
      'ê': 'e',
      'ë': 'e',
      'î': 'i',
      'ï': 'i',
      'ô': 'o',
      'ö': 'o',
      'ù': 'u',
      'û': 'u',
      'ü': 'u',
      'ç': 'c',
      'œ': 'oe',
      '’': "'",
      'ʻ': "'",
      'ʿ': "'",
      'تونس': 'tunis',
      'سوسة': 'sousse',
      'المنستير': 'monastir',
      'المهدية': 'mahdia',
    };

    replacements.forEach((k, v) {
      text = text.replaceAll(k, v);
    });

    text = text
        .replaceAll('ez zahra', 'ezzahra')
        .replaceAll('ez zahra', 'ezzahra')
        .replaceAll('ez-zahra', 'ezzahra')
        .replaceAll('saida', 'sayda')
        .replaceAll('mannoubia', 'manoubia')
        .replaceAll('echatt', 'chott')
        .replaceAll('erriadh', 'riadh')
        .replaceAll('rades', 'rades')
        .replaceAll('lycee', 'lycee')
        .replaceAll('aeroport', 'airport')
        .replaceAll('skanes monastir', 'airport')
        .replaceAll('zone industrielle', 'zi')
        .replaceAll('z ind', 'zi')
        .replaceAll('zind', 'zi');

    text = text.replaceAll(RegExp(r"[^a-z0-9\s']"), ' ');

    const stopWords = {
      'station',
      'gare',
      'arret',
      'arrêt',
      'de',
      'du',
      'des',
      'la',
      'le',
      'l',
      'el',
      'al',
      'city',
      'st',
    };

    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && !stopWords.contains(t))
        .toList();
    return tokens.join(' ');
  }

  static List<String> _normalizedAliasesForStation(Station station) {
    final rawAliases = _stationAliasesById[station.id] ?? const <String>[];
    final normalized = rawAliases
        .map(normalizeStationText)
        .where((alias) => alias.isNotEmpty)
        .toSet()
        .toList();
    normalized.sort();
    return normalized;
  }

  static double _stringSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final distance = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    return 1.0 - (distance / maxLen);
  }

  static int _levenshtein(String s, String t) {
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    final dp = List.generate(
      s.length + 1,
      (_) => List<int>.filled(t.length + 1, 0),
    );

    for (var i = 0; i <= s.length; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= t.length; j++) {
      dp[0][j] = j;
    }

    for (var i = 1; i <= s.length; i++) {
      for (var j = 1; j <= t.length; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        final deletion = dp[i - 1][j] + 1;
        final insertion = dp[i][j - 1] + 1;
        final substitution = dp[i - 1][j - 1] + cost;
        var best = deletion < insertion ? deletion : insertion;
        best = substitution < best ? substitution : best;
        dp[i][j] = best;
      }
    }

    return dp[s.length][t.length];
  }

}