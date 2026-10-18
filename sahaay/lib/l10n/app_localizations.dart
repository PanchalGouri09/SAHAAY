/// App-localised strings for SAHAAY's supported languages: English (en),
/// Hindi (hi) and Marathi (mr).
///
/// Deliberately programmatic (no code generation / ARB step) so the class is
/// available at compile time from the single-file app and can be constructed
/// directly in widget tests. [AppLocalizations.of] falls back to English when
/// no delegate is installed above the current context, so widgets remain safe
/// to pump in isolation.
///
/// English values are byte-identical to the strings that were previously
/// hardcoded in the UI, so the default English experience (and every existing
/// widget test) is unchanged. Keys cover the Settings / Profile / Help /
/// Leaderboard / My Claims / claimed-donation surfaces; screens not yet keyed
/// continue to render in English (documented limitation — see batch report).
library;

import 'package:flutter/widgets.dart';

class AppLocalizations {
  final String languageCode;
  const AppLocalizations(this.languageCode);

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('hi'),
    Locale('mr'),
  ];

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// Returns the localisations for [context], falling back to English when
  /// the delegate is not installed (isolated widget tests, bare routers).
  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations('en');

  static const Map<String, Map<String, String>> _strings = {
    'en': {
      // ---- Settings ----
      'settings': 'Settings',
      'account': 'Account',
      'editProfileDetails': 'Edit profile details',
      'notificationPreferences': 'Notification Preferences',
      'donationClaimUpdates': 'Donation & claim updates',
      'matchingAlerts': 'Matching & volunteer assignment alerts',
      'rewardUpdates': 'Reward & impact updates',
      'privacy': 'Privacy',
      'showOnLeaderboard': 'Show my organization on the public leaderboard',
      'appPreferences': 'App Preferences',
      'darkMode': 'Dark mode',
      'language': 'Language',
      'notSet': 'Not set',
      'logOut': 'LOG OUT',
      // ---- Language picker ----
      'chooseLanguage': 'Choose language',
      'languageHint': 'The app language is saved on this device.',
      'cancel': 'Cancel',
      // ---- Profile tab ----
      'profile': 'Profile',
      'publicImpactLeaderboard': 'Public Impact Leaderboard',
      'helpSupport': 'Help & Support',
      // ---- Help & support ----
      'getInTouch': 'Get in Touch',
      'contactSupport': 'Contact Support',
      'reportAProblem': 'Report a Problem',
      // ---- Leaderboard (honest unavailable state) ----
      'leaderboardHeader': 'City-level impact, ranked by food redistributed',
      'leaderboardUnavailable':
          'Leaderboards are not available yet. SAHAAY does not show rankings until real leaderboard data exists on the backend.',
      'notYetAvailable': 'NOT YET AVAILABLE',
      'pointsNotTracked':
          'Impact points are not tracked yet — SAHAAY has no backend rewards data, so no points are shown.',
      // ---- My Claims ----
      'myClaims': 'My Claims',
      'noClaimsYet':
          'No active claims yet. Claim a donation from Find Food.',
      'claimsLoadFailed':
          'Could not load your claims. Check your connection and try again.',
      'retry': 'Retry',
      // ---- Claimed donation / handover ----
      'claimedDonation': 'Claimed Donation',
      'location': 'Location',
      'restaurantInformation': 'Restaurant Information',
      'volunteer': 'Volunteer',
      'handoverVerification': 'Handover Verification',
      'handoverPhoto': 'Handover Photo',
      'verifyHandover': 'VERIFY & CONFIRM HANDOVER',
      'addHandoverPhoto': 'ADD HANDOVER PHOTO',
      'replacePhoto': 'REPLACE PHOTO',
      'shareCodeHint':
          'Share this code with the NGO representative at pickup to confirm handover.',
      'enterHandoverCode': 'Enter handover code',
      'handoverVerifiedMsg': 'Handover verified successfully.',
      'generatingCode': 'Generating handover code…',
      'newCode': 'GENERATE NEW CODE',
      // ---- Edit profile ----
      'editProfile': 'Edit Profile',
      'fullName': 'Full name',
      'phone': 'Phone',
      'organizationName': 'Organization name',
      'address': 'Address',
      'city': 'City',
      'description': 'Description',
      'contactPhone': 'Contact phone',
      'registrationNumber': 'Registration number',
      'availabilityStatus': 'Availability status',
      'vehicleType': 'Vehicle type',
      'saveChanges': 'SAVE CHANGES',
      'saving': 'Saving…',
      'profileUpdated': 'Profile updated.',
      'profilePhoto': 'Profile photo',
      'changePhoto': 'CHANGE PHOTO',
      'uploadPhoto': 'UPLOAD PHOTO',
      'uploading': 'Uploading…',
      'requiredField': 'This field is required.',
    },
    'hi': {
      // ---- Settings ----
      'settings': 'सेटिंग्स',
      'account': 'खाता',
      'editProfileDetails': 'प्रोफ़ाइल विवरण संपादित करें',
      'notificationPreferences': 'सूचना प्राथमिकताएँ',
      'donationClaimUpdates': 'दान और दावे के अपडेट',
      'matchingAlerts': 'मिलान और स्वयंसेवक असाइनमेंट अलर्ट',
      'rewardUpdates': 'पुरस्कार और प्रभाव अपडेट',
      'privacy': 'गोपनीयता',
      'showOnLeaderboard': 'सार्वजनिक लीडरबोर्ड पर मेरा संगठन दिखाएँ',
      'appPreferences': 'ऐप प्राथमिकताएँ',
      'darkMode': 'डार्क मोड',
      'language': 'भाषा',
      'notSet': 'सेट नहीं है',
      'logOut': 'लॉग आउट',
      // ---- Language picker ----
      'chooseLanguage': 'भाषा चुनें',
      'languageHint': 'ऐप की भाषा इस डिवाइस पर सहेजी जाती है।',
      'cancel': 'रद्द करें',
      // ---- Profile tab ----
      'profile': 'प्रोफ़ाइल',
      'publicImpactLeaderboard': 'सार्वजनिक प्रभाव लीडरबोर्ड',
      'helpSupport': 'सहायता और समर्थन',
      // ---- Help & support ----
      'getInTouch': 'संपर्क में रहें',
      'contactSupport': 'सहायता से संपर्क करें',
      'reportAProblem': 'समस्या की रिपोर्ट करें',
      // ---- Leaderboard (honest unavailable state) ----
      'leaderboardHeader': 'शहर स्तर का प्रभाव, पुनर्वितरित भोजन के आधार पर रैंकिंग',
      'leaderboardUnavailable':
          'लीडरबोर्ड अभी उपलब्ध नहीं है। बैकएंड पर वास्तविक लीडरबोर्ड डेटा होने तक SAHAAY रैंकिंग नहीं दिखाता।',
      'notYetAvailable': 'अभी उपलब्ध नहीं',
      'pointsNotTracked':
          'इम्पैक्ट पॉइंट्स अभी ट्रैक नहीं किए जाते — SAHAAY में कोई बैकएंड रिवॉर्ड्स डेटा नहीं है, इसलिए कोई पॉइंट्स नहीं दिखाए जाते।',
      // ---- My Claims ----
      'myClaims': 'मेरे दावे',
      'noClaimsYet': 'अभी कोई सक्रिय दावा नहीं। भोजन खोजें से कोई दान दावा करें।',
      'claimsLoadFailed':
          'आपके दावे लोड नहीं हो सके। अपना कनेक्शन जाँचें और पुनः प्रयास करें।',
      'retry': 'पुनः प्रयास करें',
      // ---- Claimed donation / handover ----
      'claimedDonation': 'दावा किया गया दान',
      'location': 'स्थान',
      'restaurantInformation': 'रेस्तरां की जानकारी',
      'volunteer': 'स्वयंसेवक',
      'handoverVerification': 'हस्तांतरण सत्यापन',
      'handoverPhoto': 'हस्तांतरण फ़ोटो',
      'verifyHandover': 'हस्तांतरण सत्यापित और पुष्टि करें',
      'addHandoverPhoto': 'हस्तांतरण फ़ोटो जोड़ें',
      'replacePhoto': 'फ़ोटो बदलें',
      'shareCodeHint':
          'हस्तांतरण की पुष्टि के लिए पिकअप पर NGO प्रतिनिधि के साथ यह कोड साझा करें।',
      'enterHandoverCode': 'हस्तांतरण कोड दर्ज करें',
      'handoverVerifiedMsg': 'हस्तांतरण सफलतापूर्वक सत्यापित हुआ।',
      'generatingCode': 'हस्तांतरण कोड बनाया जा रहा है…',
      'newCode': 'नया कोड बनाएँ',
      // ---- Edit profile ----
      'editProfile': 'प्रोफ़ाइल संपादित करें',
      'fullName': 'पूरा नाम',
      'phone': 'फ़ोन',
      'organizationName': 'संगठन का नाम',
      'address': 'पता',
      'city': 'शहर',
      'description': 'विवरण',
      'contactPhone': 'संपर्क फ़ोन',
      'registrationNumber': 'पंजीकरण संख्या',
      'availabilityStatus': 'उपलब्धता स्थिति',
      'vehicleType': 'वाहन का प्रकार',
      'saveChanges': 'परिवर्तन सहेजें',
      'saving': 'सहेजा जा रहा है…',
      'profileUpdated': 'प्रोफ़ाइल अपडेट हो गई।',
      'profilePhoto': 'प्रोफ़ाइल फ़ोटो',
      'changePhoto': 'फ़ोटो बदलें',
      'uploadPhoto': 'फ़ोटो अपलोड करें',
      'uploading': 'अपलोड हो रहा है…',
      'requiredField': 'यह फ़ील्ड आवश्यक है।',
    },
    'mr': {
      // ---- Settings ----
      'settings': 'सेटिंग्ज',
      'account': 'खाते',
      'editProfileDetails': 'प्रोफाइल तपशील संपादित करा',
      'notificationPreferences': 'सूचना प्राधान्ये',
      'donationClaimUpdates': 'दान व दाव्याचे अपडेट',
      'matchingAlerts': 'जुळवणी व स्वयंसेवक नेमणूक अलर्ट',
      'rewardUpdates': 'बक्षीस व प्रभाव अपडेट',
      'privacy': 'गोपनीयता',
      'showOnLeaderboard': 'सार्वजनिक लीडरबोर्डवर माझे संस्थेचे नाव दाखवा',
      'appPreferences': 'अॅप प्राधान्ये',
      'darkMode': 'डार्क मोड',
      'language': 'भाषा',
      'notSet': 'सेट केलेले नाही',
      'logOut': 'लॉग आउट',
      // ---- Language picker ----
      'chooseLanguage': 'भाषा निवडा',
      'languageHint': 'अॅपची भाषा या डिव्हाइसवर जतन केली जाते.',
      'cancel': 'रद्द करा',
      // ---- Profile tab ----
      'profile': 'प्रोफाइल',
      'publicImpactLeaderboard': 'सार्वजनिक प्रभाव लीडरबोर्ड',
      'helpSupport': 'मदत व समर्थन',
      // ---- Help & support ----
      'getInTouch': 'संपर्कात राहा',
      'contactSupport': 'समर्थनाशी संपर्क साधा',
      'reportAProblem': 'समस्येचा तक्रार करा',
      // ---- Leaderboard (honest unavailable state) ----
      'leaderboardHeader': 'शहर स्तराचा प्रभाव, पुनर्वितरित अन्नानुसार रैंकिंग',
      'leaderboardUnavailable':
          'लीडरबोर्ड अद्याप उपलब्ध नाही. बॅकएंडवर खऱ्या लीडरबोर्ड डेटा न होईपर्यंत SAHAAY रैंकिंग दाखवत नाही.',
      'notYetAvailable': 'अद्याप उपलब्ध नाही',
      'pointsNotTracked':
          'इम्पॅक्ट पॉईंट्स अद्याप ट्रॅक केले जात नाहीत — SAHAAY मध्ये कोणताही बॅकएंड बक्षीस डेटा नाही, म्हणून कोणतेही पॉईंट्स दाखवले जात नाहीत.',
      // ---- My Claims ----
      'myClaims': 'माझे दावे',
      'noClaimsYet': 'अद्याप कोणताही सक्रिय दावा नाही. शोधा यातून दान दावा करा.',
      'claimsLoadFailed':
          'तुमचे दावे लोड होऊ शकले नाही. तुमचे कनेक्शन तपासा आणि पुन्हा प्रयत्न करा.',
      'retry': 'पुन्हा प्रयत्न करा',
      // ---- Claimed donation / handover ----
      'claimedDonation': 'दावा केलेले दान',
      'location': 'स्थान',
      'restaurantInformation': 'रेस्टॉरंट माहिती',
      'volunteer': 'स्वयंसेवक',
      'handoverVerification': 'हस्तांतरण पडताळणी',
      'handoverPhoto': 'हस्तांतरण फोटो',
      'verifyHandover': 'हस्तांतरण पडताळून निश्चित करा',
      'addHandoverPhoto': 'हस्तांतरण फोटो जोडा',
      'replacePhoto': 'फोटो बदला',
      'shareCodeHint':
          'हस्तांतरणाची खात्री करण्यासाठी पिकअपवेळी NGO प्रतिनिधीसोबत हा कोड शेअर करा.',
      'enterHandoverCode': 'हस्तांतरण कोड टाका',
      'handoverVerifiedMsg': 'हस्तांतरण यशस्वीरित्या पडताळले.',
      'generatingCode': 'हस्तांतरण कोड तयार होत आहे…',
      'newCode': 'नवीन कोड तयार करा',
      // ---- Edit profile ----
      'editProfile': 'प्रोफाइल संपादित करा',
      'fullName': 'पूर्ण नाव',
      'phone': 'फोन',
      'organizationName': 'संस्थेचे नाव',
      'address': 'पत्ता',
      'city': 'शहर',
      'description': 'वर्णन',
      'contactPhone': 'संपर्क फोन',
      'registrationNumber': 'नोंदणी क्रमांक',
      'availabilityStatus': 'उपलब्धता स्थिती',
      'vehicleType': 'वाहनाचा प्रकार',
      'saveChanges': 'बदल जतन करा',
      'saving': 'जतन करत आहे…',
      'profileUpdated': 'प्रोफाइल अपडेट झाली.',
      'profilePhoto': 'प्रोफाइल फोटो',
      'changePhoto': 'फोटो बदला',
      'uploadPhoto': 'फोटो अपलोड करा',
      'uploading': 'अपलोड होत आहे…',
      'requiredField': 'ही फील्ड आवश्यक आहे.',
    },
  };

  String t(String key) {
    final localized = _strings[languageCode];
    return localized?[key] ?? _strings['en']![key] ?? key;
  }

  // ---- Settings ----
  String get settings => t('settings');
  String get account => t('account');
  String get editProfileDetails => t('editProfileDetails');
  String get notificationPreferences => t('notificationPreferences');
  String get donationClaimUpdates => t('donationClaimUpdates');
  String get matchingAlerts => t('matchingAlerts');
  String get rewardUpdates => t('rewardUpdates');
  String get privacy => t('privacy');
  String get showOnLeaderboard => t('showOnLeaderboard');
  String get appPreferences => t('appPreferences');
  String get darkMode => t('darkMode');
  String get language => t('language');
  String get notSet => t('notSet');
  String get logOut => t('logOut');

  // ---- Language picker ----
  String get chooseLanguage => t('chooseLanguage');
  String get languageHint => t('languageHint');
  String get cancel => t('cancel');

  // ---- Profile tab ----
  String get profile => t('profile');
  String get publicImpactLeaderboard => t('publicImpactLeaderboard');
  String get helpSupport => t('helpSupport');

  // ---- Help & support ----
  String get getInTouch => t('getInTouch');
  String get contactSupport => t('contactSupport');
  String get reportAProblem => t('reportAProblem');

  // ---- Leaderboard ----
  String get leaderboardHeader => t('leaderboardHeader');
  String get leaderboardUnavailable => t('leaderboardUnavailable');
  String get notYetAvailable => t('notYetAvailable');
  String get pointsNotTracked => t('pointsNotTracked');

  // ---- My Claims ----
  String get myClaims => t('myClaims');
  String get noClaimsYet => t('noClaimsYet');
  String get claimsLoadFailed => t('claimsLoadFailed');
  String get retry => t('retry');

  // ---- Claimed donation / handover ----
  String get claimedDonation => t('claimedDonation');
  String get location => t('location');
  String get restaurantInformation => t('restaurantInformation');
  String get volunteer => t('volunteer');
  String get handoverVerification => t('handoverVerification');
  String get handoverPhoto => t('handoverPhoto');
  String get verifyHandover => t('verifyHandover');
  String get addHandoverPhoto => t('addHandoverPhoto');
  String get replacePhoto => t('replacePhoto');
  String get shareCodeHint => t('shareCodeHint');
  String get enterHandoverCode => t('enterHandoverCode');
  String get handoverVerifiedMsg => t('handoverVerifiedMsg');
  String get generatingCode => t('generatingCode');
  String get newCode => t('newCode');

  // ---- Edit profile ----
  String get editProfile => t('editProfile');
  String get fullName => t('fullName');
  String get phone => t('phone');
  String get organizationName => t('organizationName');
  String get address => t('address');
  String get city => t('city');
  String get description => t('description');
  String get contactPhone => t('contactPhone');
  String get registrationNumber => t('registrationNumber');
  String get availabilityStatus => t('availabilityStatus');
  String get vehicleType => t('vehicleType');
  String get saveChanges => t('saveChanges');
  String get saving => t('saving');
  String get profileUpdated => t('profileUpdated');
  String get profilePhoto => t('profilePhoto');
  String get changePhoto => t('changePhoto');
  String get uploadPhoto => t('uploadPhoto');
  String get uploading => t('uploading');
  String get requiredField => t('requiredField');

  /// Display name for a language code, always shown in its own language.
  static String languageName(String code) {
    switch (code) {
      case 'hi':
        return 'हिन्दी';
      case 'mr':
        return 'मराठी';
      default:
        return 'English';
    }
  }
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.supportedLocales
          .any((l) => l.languageCode == locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
