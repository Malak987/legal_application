import '../../models/samaha_catalog.dart';

/// Deliberately scoped bilingual UI, not machine-translated staff identities.
class SamahaStrings {
  const SamahaStrings(this.language);
  final String language;
  bool get isArabic => language == 'ar';
  String t(String en, String ar) => isArabic ? ar : en;
  String get directoryLabel =>
      t('SAMAHA GROUP / DIRECTORY', 'سماحة جروب / الدليل');
  String get homeHeadline => t(
    'Clear information.\nConfident decisions.',
    'معلومات واضحة.\nقرارات بثقة.',
  );
  String get homeIntro => t(
    'Explore the group, its published services and the people behind them. All in one considered space.',
    'تعرّف على المجموعة وخدماتها المنشورة وملفات فريقها، في تجربة واحدة واضحة.',
  );
  String get peopleHeadline =>
      t('People & perspectives', 'الفريق والخبرات المنشورة');
  String get servicesHeadline =>
      t('Expertise, clearly organised', 'خدمات واضحة، في مكان واحد');
  String get locationHeadline =>
      t('Find your point of contact', 'اعثر على وجهة التواصل');
  String get allRoles => t('All roles', 'كل المسميات');
  String get roleFilter => t('Published role', 'المسمى المنشور');
  String get sourcePhoto => t('Source photograph', 'صورة من المصدر');
  String get rightsUnknown => t(
    'The requester declared photo permission; no permission document was supplied or independently verified.',
    'أقرّ صاحب الطلب بوجود إذن للصورة؛ لم تُرفق وثيقة الإذن أو تُدقّق بصورة مستقلة.',
  );
  String get teamDirectoryNotice => t(
    'Published company profiles, not platform lawyer accounts. Photo permission declared by the requester; documentation not supplied.',
    'ملفات منشورة للشركة وليست حسابات محامي المنصة. أقرّ صاحب الطلب بإذن الصور؛ لم تُرفق وثيقته.',
  );
  String get photoNotice => t(
    'Source photographs are shown on the requester’s permission declaration, not an independently verified licence. Ambiguous associations use a neutral placeholder.',
    'تُعرض صور المصدر استنادًا إلى إقرار صاحب الطلب بالإذن، لا إلى ترخيص مدقّق مستقلاً. تظهر صور بديلة محايدة عند التباس النسبة.',
  );
  String get portraitUnavailable =>
      t('Verified portrait unavailable', 'لا تتوفر صورة موثوقة النسبة');
  String get roleUnderReview =>
      t('Role wording under review', 'صياغة المسمى قيد المراجعة');
  String get publishedProfiles => t('Published profiles', 'ملفات منشورة');
  String get sourceVariants =>
      t('Original published variants', 'الصياغات الأصلية المنشورة');
  String get directoryIntro => t(
    'Five distinct divisions. A clear view of the services published by each.',
    'خمسة أقسام متخصصة، وعرض واضح للخدمات المنشورة لكل قسم.',
  );
  String get registeredServices => t('Legal Services', 'الخدمات القانونية');
  String get registeredNotice => t(
    'Registered platform lawyers · Separate from the company directory',
    'محامو المنصة المسجلون · مستقلون عن دليل الشركة',
  );
  String get findLawyer =>
      t('Find Best Lawyers with us', 'ابحث عن محامي المنصة المناسب');
  String get results => t('results', 'نتيجة');
  String get companies => t('Companies & divisions', 'الشركات والأقسام');
  String get explore => t('Explore Samaha Group', 'اكتشف سماحة جروب');
  String get aboutGroup => t('About the group', 'عن المجموعة');
  String get viewAll => t('View all', 'عرض الكل');
  String get details => t('View details', 'عرض التفاصيل');
  String get services => t('Services', 'الخدمات');
  String get team => t('Team', 'الفريق');
  String get branches => t('Published locations', 'المواقع المنشورة');
  String get faqs => t('Questions & answers', 'الأسئلة والأجوبة');
  String get articles => t('Articles', 'المقالات');
  String get loading => t('Loading the directory…', 'جارٍ تحميل الدليل…');
  String get unavailable =>
      t('The directory is unavailable', 'الدليل غير متاح حاليًا');
  String get assetHelp => t(
    'This directory is included in the app. Retry loading it; if the problem continues, update or reinstall the app.',
    'هذا الدليل مضمّن في التطبيق. أعد تحميله، وإذا استمرت المشكلة فحدّث التطبيق أو أعد تثبيته.',
  );
  String get retry => t('Retry directory', 'إعادة تحميل الدليل');
  String get empty => t(
    'No reviewed information is available here yet.',
    'لا تتوفر معلومات معتمدة للعرض هنا بعد.',
  );
  String get noResults => t(
    'No matching results. Try another name or division.',
    'لا توجد نتائج مطابقة. جرّب اسمًا أو قسمًا آخر.',
  );
  String get search => t('Search this directory', 'ابحث في هذا الدليل');
  String get allCompanies => t('All divisions', 'كل الأقسام');
  String get filterCompany => t('Filter by division', 'التصفية حسب القسم');
  String get clearFilters => t('Clear filters', 'مسح التصفية');
  String get notFound => t(
    'This information is not available for publication.',
    'هذه المعلومات غير متاحة للنشر.',
  );
  String get overview => t('Overview', 'نبذة');
  String get publishedRole => t('Published role', 'المسمّى المنشور');
  String get publishedOffice =>
      t('Office wording on the source', 'المكتب كما ورد في المصدر');
  String get publishedAddress => t('Published address', 'العنوان المنشور');
  String get locationNotice => t(
    'A published location is not confirmation of an operating office. Confirm the address and availability before visiting.',
    'نشر موقع لا يُعد تأكيدًا على وجود مكتب عامل. يُرجى التأكد من العنوان وتوفر الخدمة قبل الزيارة.',
  );
  String get teamNotice => t(
    'These are informational company profiles, not registered Legal platform lawyer accounts. Names and roles are reproduced as published; no credentials or appointment availability are inferred.',
    'هذه ملفات تعريفية من مصادر الشركة، وليست حسابات محامين مسجلين على منصة Legal. الأسماء والمسميات منقولة كما نُشرت دون استنتاج مؤهلات أو مواعيد متاحة.',
  );
  String get sourceNotice => t(
    'Based on the company’s published information. Confirm current services and terms directly with the division.',
    'استنادًا إلى المعلومات المنشورة للشركة. يُرجى التأكد من الخدمات والشروط الحالية مباشرة مع القسم.',
  );
  String get contacts => t('Company enquiries', 'التواصل مع الشركة');
  String get branchContacts =>
      t('Published location contacts', 'وسائل التواصل المنشورة للموقع');
  String get noContacts => t(
    'No reviewed direct contact is available for this division.',
    'لا توجد وسيلة تواصل مباشر معتمدة للعرض لهذا القسم.',
  );
  String get sources => t('Sources & provenance', 'المصادر والتوثيق');
  String get related => t('Related information', 'معلومات مرتبطة');
  String get officialWebsite =>
      t('Visit Official Website', 'زيارة الموقع الرسمي للشركة');
  String get websiteUnavailable =>
      t('Official website unavailable', 'الموقع الرسمي غير متاح');
  String get noWebsite => t(
    'No reviewed HTTPS website is available for this company.',
    'لا يتوفر موقع HTTPS معتمد للعرض لهذه الشركة.',
  );
  String get externalWebsite => t(
    'Opens outside Legal in your browser. An internet connection may be needed.',
    'يُفتح خارج Legal في المتصفح، وقد يتطلب اتصالًا بالإنترنت.',
  );
  String get offlineDirectory => t(
    'Samaha Group · Offline directory',
    'سماحة جروب · دليل متاح دون إنترنت',
  );
  String get browseOffline =>
      t('Browse Samaha Group (offline)', 'تصفح سماحة جروب دون إنترنت');
  String get servicesAndSpecializations =>
      t('Services & specializations', 'الخدمات والتخصصات');
  String get foundersAndTeam =>
      t('Founders & published team', 'المؤسسون والفريق المنشور');
  String get noFounders => t(
    'No founder profile has been approved for publication for this company.',
    'لم يُعتمد ملف مؤسس للعرض لهذه الشركة.',
  );
  String get noTeam => t(
    'No reviewed team profiles are available for this company.',
    'لا تتوفر ملفات فريق معتمدة للعرض لهذه الشركة.',
  );
  String get biography => t('Biography', 'السيرة الذاتية');
  String get noBiography => t(
    'No reviewed biography is available.',
    'لا تتوفر سيرة ذاتية معتمدة للعرض.',
  );
  String get specialties => t('Individual specialties', 'التخصصات الفردية');
  String get noSpecialties => t(
    'No individual specialties are published in the reviewed sources.',
    'لم ترد تخصصات فردية في المصادر المعتمدة للعرض.',
  );
  String get noRole =>
      t('Published role unavailable', 'المسمّى المنشور غير متاح');
  String teamCategory(SamahaTeamCategory category) => switch (category) {
    SamahaTeamCategory.founder => t('Founders', 'المؤسسون'),
    SamahaTeamCategory.partner => t('Partners', 'الشركاء'),
    SamahaTeamCategory.lawyer => t(
      'Source-listed lawyers',
      'المحامون وفق المصدر',
    ),
    SamahaTeamCategory.legalProfessional => t(
      'Researchers & legal consultants',
      'الباحثون والمستشارون القانونيون',
    ),
    SamahaTeamCategory.other => t(
      'Other published roles',
      'مسميات أخرى منشورة',
    ),
  };
  String get openLink => t('Open link', 'فتح الرابط');
  String get copy => t('Copy', 'نسخ');
  String get copied => t('Copied', 'تم النسخ');
  String get linkFailed => t(
    'Could not open this app or link. You can copy the published contact instead.',
    'تعذّر فتح التطبيق أو الرابط. يمكنك نسخ وسيلة التواصل المنشورة بدلًا من ذلك.',
  );
  String get refresh => t('Refresh directory', 'تحديث الدليل');
  String get originalLanguage =>
      t('Shown in its available source language', 'يُعرض بلغة المصدر المتاحة');
  String kind(SamahaEntryKind kind) => switch (kind) {
    SamahaEntryKind.service => services,
    SamahaEntryKind.person => team,
    SamahaEntryKind.branch => branches,
    SamahaEntryKind.faq => faqs,
    SamahaEntryKind.article => articles,
    SamahaEntryKind.contact => contacts,
    SamahaEntryKind.testimonial => t('Testimonials', 'آراء العملاء'),
    SamahaEntryKind.partner => t('Clients & partners', 'العملاء والشركاء'),
  };
  String action(String kind) => switch (kind) {
    'phone' => t('Call', 'اتصال'),
    'email' => t('Email', 'بريد إلكتروني'),
    'whatsapp' => t('WhatsApp', 'واتساب'),
    'map' => t('Open published map', 'فتح الخريطة المنشورة'),
    _ => openLink,
  };
}
