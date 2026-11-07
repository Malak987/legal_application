# Phase 4 — التقرير النهائي (حذف الحساب الذاتي + شبكة الرئيسية بعمودين)

**التاريخ:** 2026-11-05 · **الفرع:** `main` · **آخر commit:** `c5a6173` (لم أُجرِ أي commit أو push)

---

## 1. الخلاصة التنفيذية

| البند | الحالة |
|---|---|
| الميزة 1: حذف الحساب من داخل التطبيق | مكتملة ومُختبرة محليًا (Flutter + Edge Function) — **غير منشورة على Supabase** |
| الميزة 2: شبكة الرئيسية بعمودين على الجوال | مكتملة و**مُختبرة: 18/18 نجحت** |
| `deno test` لدالة الحذف | **نجح: 20/20** |
| اختبارات Dart الجديدة للحذف | **نجحت: 17/17** (10 + 7) |
| `flutter analyze` على الملفات المتغيّرة | **`No issues found!`** — 9 ملفات |
| خط الأساس الكامل `flutter test` | **لم يكتمل** (توقّف عند 15 اختبارًا بعد 28 دقيقة) — §8 |
| أي نشر أو SQL | **لا شيء** — لم يُطبَّق أي SQL ولم تُنشر أي دالة |

---

## 2. حالة git

```
$ git log --oneline -1
c5a6173 restored working tree baseline (pre-task)

$ git status --porcelain
 M lib/services/api_client.dart
 M lib/state/session_controller.dart
 M lib/views/home/homescreen.dart
 M lib/views/profile/profile_screen.dart
 M test/home_restore_layout_test.dart
?? lib/views/profile/delete_account.dart
?? supabase/
?? test/account_deletion_controller_test.dart
?? test/account_deletion_screen_test.dart
?? test/support/deletion_harness.dart
```

لا commit، لا push، ولا أوامر git مدمِّرة.

---

## 3. الملفات المتغيّرة

**جديدة:**
- `lib/views/profile/delete_account.dart` — شاشة الحذف (`DeleteAccountScreen`).
- `supabase/functions/delete-my-account/index.ts` — مدخل Deno.
- `supabase/functions/delete-my-account/account_deletion.ts` — المعالج القابل للاختبار.
- `supabase/functions/delete-my-account/account_deletion_test.ts` — 20 اختبارًا.
- `test/account_deletion_controller_test.dart` — 8 اختبارات (ApiClient + SessionController).
- `test/account_deletion_screen_test.dart` — 6 اختبارات واجهة.
- `test/support/deletion_harness.dart` — حزمة الاختبار المشتركة.

**معدّلة:**
- `lib/services/api_client.dart` — `deleteMyAccount()` + `ApiException.code`/`withCode()`.
- `lib/state/session_controller.dart` — `deleteAccount()`، `isDeletingAccount`، `deletedAccountUid`.
- `lib/views/profile/profile_screen.dart` — صف «حذف الحساب».
- `lib/views/home/homescreen.dart` — أبعاد الشبكة.
- `test/home_restore_layout_test.dart` — توقعات العمودين والفراغ 12، وحذف فرع العمود الواحد الميت.

---

## 4. الميزة 1 — معمارية الحذف

**المسار:** `ProfileScreen` ← صف «حذف الحساب» ← `DeleteAccountScreen` ← كتابة كلمة «حذف» ← زر معطّل حتى تُكتب ← `AlertDialog` ثانٍ ← `SessionController.deleteAccount()` ← `ApiClient.deleteMyAccount()` ← `POST /functions/v1/delete-my-account`.

**ضمانات التفويض (من جهة الخادم فقط):**
1. الهدف = `auth.uid()` المستخرج من JWT بعد التحقق منه في الدالة نفسها (لا يُقبل أي معرّف مستخدم من الجسم).
2. رفض صريح لأي محاولة تمرير هدف بديل: `TARGET_NOT_ALLOWED` (403).
3. لا مفتاح service-role في التطبيق؛ يُقرأ فقط من بيئة Deno داخل الدالة.
4. الحذف الوحيد المسموح هو حساب المستخدم المستدعي، عبر Admin API.
5. حماية حسابات owner/admin، ومنع حذف محامٍ له ملف قائم (`LAWYER_PROFILE_REQUIRES_DEACTIVATION`، 409).
6. استجابات منظّمة بلا بيانات شخصية، وبلا تسجيل لأي محتوى حسّاس، والمفاتيح `alreadyDeleted`/`profileRetained` تتعامل مع التكرار بأمان.
7. عند فشل حذف حساب Auth تُستعاد بيانات الملف (rollback) بدل ترك حالة نصفية.

**جانب التطبيق:** مؤشر انتظار + `AbsorbPointer` يمنع الإرسال المزدوج، وأي فشل يُظهر خطأً صريحًا ويُبقي الجلسة — لا يظهر نجاح إلا بعد `{deleted:true}`؛ وبعد النجاح تُمسح الجلسة والاعتمادات والكاش ونُنقل إلى `LoginScreen` عبر `pushAndRemoveUntil((route) => false)`.

**قرار مقصود:** لم أُعِد استخدام `admin-delete-account` لأنه يشترط مستدعيًا من owner/admin ويطلب `profileId` لمستخدم آخر ويحظر حذف الذات.

---

## 5. تدقيق الاحتفاظ (العلاقات) — قبل أي تغيير هيكلي

| العلاقة | السلوك عند حذف مستخدم Auth | القرار |
|---|---|---|
| `public.users.auth_user_id` | `SET NULL` عبر `guard_user_identity_fields()` الذي يسمح بهذا الشكل تحديدًا | ✅ الطريق الصحيح |
| 12 علاقة تابعة لـ `public.users` (bookings, chat_messages, favorites, reviews, wallets, subscriptions, notifications, tasks, earnings, wallet_transactions, wallet_idempotency, booking_slots) | `ON DELETE CASCADE` | ⛔ **لا يُحذف صف الملف أبدًا** — وإلا دُمّر تاريخ الطرف الآخر |
| `storage.objects` | لا توجد كائنات (0) | لا حاجة لتنظيف تخزين |

**النتيجة:** حذف مستخدم Auth وحده، مع إبقاء الملف (يُجهَّل الاسم/البريد/الهاتف/الصورة/العنوان) ثم `SET NULL` للمعرّف. **لا migration مطلوبة ولا مُنشأة ولا مُطبَّقة.**

⚠️ خطر مُسجَّل: `trg_auth_users_link_migrated` يُنشئ ملفًا جديدًا إذا أُعيد استخدام البريد نفسه (لأن `idx_users_email_lower` غير فريد).

---

## 6. الميزة 2 — شبكة الرئيسية

```dart
const spacing = 12.0;
const minCardWidth = 128.0;
final maxColumnsByWidth = ((width + spacing) / (minCardWidth + spacing)).floor();
final columns = maxColumnsByWidth.clamp(1, 2);
final cardWidth = (width - (columns - 1) * spacing) / columns;
final cardHeight = min(420, max(318, cardWidth * 1.32)) + max(0, scale - 1) * 160;
```

عرض البطاقة الناتج: 320→136، 360→158، 390→173، 430→191 dp؛ والشاشات العريضة تبقى على 2 كحد أقصى داخل الشبكة المتجاوبة. الفراغان الأفقي والعمودي = `spacing` نفسه. الأبعاد مشتقة من المحتوى والعرض، لا ثوابت عشوائية، ولم يُغيَّر أي محتوى/أيقونة/لون/تنقّل ولا ترتيب الأقسام.

---

## 7. الأوامر ونتائجها الحقيقية

| الأمر | النتيجة |
|---|---|
| `deno test supabase/functions/delete-my-account/` | `ok | 20 passed | 0 failed (24ms)` |
| `flutter test test/home_restore_layout_test.dart` | **18/18 نجحت**؛ أول تشغيل (كاش دافئ) طبع `All tests passed!`، والتشغيلات التالية طبع `+18 -1` حيث `-1` هو انهيار المترجم نفسه في المحاولة الأولى (`The Dart compiler exited unexpectedly`) ثم يعيد الترجمة ويكمل |
| `flutter test test/account_deletion_controller_test.dart` | **`All tests passed!` — 10/10** |
| `flutter test test/account_deletion_screen_test.dart` | **`All tests passed!` — 7/7** |
| `flutter analyze` على 9 ملفات متغيّرة | **`No issues found! (ran in 11.8s)`** |
| `dart format --output=none` على 9 ملفات | نجح التحليل النحوي لكل الملفات (`Formatted 9 files`) |
| `flutter test` (الخط الكامل) | **لم يكتمل**: `+15` بعد 28 دقيقة ثم توقّف عند ترجمة `samaha_offline_navigation_test.dart` |

---

## 8. ما جرى مع الاختبارات (وتصحيح التقرير الأولي)

- في محاولة واحدة **فعلًا نُفِّذت** النسخة الأولى من الملف الموحَّد: `13 +  pass / 5 fail`، ثم صحّحت أسباب الفشل الخمسة من الكود نفسه:
  1. المحامي في الاختبار كان بلا `onboarding_status: active` فرفضه `AuthService.loadProfile` (`role-not-authorized`) — عُولج في `deletion_harness.dart`.
  2. `find.text` المكرر في الحوار — أضفت `ValueKey('delete-account-dialog-confirm'/'…-cancel')` إلى الشاشة.
  3. `DeleteAccountScreen` لا يزال في الشجرة أثناء انتقال المسار — أضفت تدوير ساعة الاختبار قبل التأكيد.
  4. `expectLater` خارج `runAsync` — نُقل إلى الداخل.
  5. حالة التحميل — أُعيدت صياغتها بـ `Completer` بدل مؤقت حقيقي.
- بعد ذلك حذفت `.dart_tool`/`build` لإصلاح حالة عالقة ففقدتُ كاش النواة الدافئ، وتوقّفت كل محاولات `flutter test` و`flutter analyze` مؤقتًا.
- **السبب الحقيقي:** كان `/tmp` (tmpfs = ذاكرة RAM) يحتوي 641 MB من مجلدات `flutter_tools.*` من عمليات سابقة مقتولة، فلم يبقَ للترجمة إلا ~750 MB.
- بعد حذفها (صار المتاح 1347 MB) نجحت الترجمة، وأُعيد تشغيل الاختبارات الحقيقية:
  - `account_deletion_controller_test.dart` → **10/10 نجحت نظيفة** (بما فيها: لا معرّف مستخدم في الجسم، مسح الجلسة بعد النجاح، ثلاث حالات فشل لا تُخرج المستخدم، `deleted:false` لا يُعدّ نجاحًا، رفض المحامي 409، الإرسال المتزامن = طلب واحد فقط، وحذف أثناء الخروج يُرفض محليًا).
  - `account_deletion_screen_test.dart` → **7/7 نجحت** (نقطة الدخول العربية، الزر معطّل حتى تُكتب الكلمة، نقرة أولى تفتح الحوار فقط، النجاح ينقل إلى شاشة الدخول ويُزيل الشاشة من الشجرة، الفشل يُظهر خطأً ولا ينقل، حالة التحميل تُعطّل الزر، واتجاه RTL).
- ملاحظة بيئية مسجَّلة: على هذا الصندوق (1982 MB / نواتان) ينهار `frontend_server` أحيانًا في محاولة الترجمة الأولى ثم يُعيد Flutter المحاولة؛ لذلك تظهر أحيانًا لقطة `-1` باسم `loading ...` بينما كل الاختبارات تمر. هذا قيد بيئة لا فشل اختبار.
- **الخط الكامل `flutter test` لم يكتمل:** بعد 15 اختبارًا ناجحًا من أول 4 ملفات، توقّف 28 دقيقة عند ترجمة `samaha_offline_navigation_test.dart` (نفس عنق الزجاجة: ذاكرة 2 GB). لذلك **لا أزعم نجاح 371 اختبارًا**.

**لتشغيل الخط الكامل على جهازك (ما زال مطلوبًا):**

```bash
cd "/run/media/malak_3zat/Hdd 1/flutter project/تطبيق/legal_app"
flutter test                    # خط الأساس الكامل — لم يكتمل هنا
flutter analyze lib test
cd supabase/functions/delete-my-account && deno test
```

الملفات الجديدة سليمة ومُختبرة هنا، لذا من المتوقع أن يمر الخط الكامل؛ لكن **لن أزعم ذلك قبل تشغيله**.

---

## 9. ما لم يُتحقَّق منه

- خط الأساس الكامل لـ `flutter test` (31 ملفًا): توقّف بسبب قيد ذاكرة البيئة، لا بسبب فشل اختبار.
- `samaha_offline_navigation_test.dart` وملفات لاحقة لم تُشغَّل هنا.
- `flutter analyze lib test` (النطاق الكامل) — نُفِّذ على الملفات المتغيّرة فقط كي لا ينفد الوقت/الذاكرة.
- التحقق البصري على أجهزة 320/360/390/430 dp حقيقية — المتاح هو اختبارات تخطيط آلية عند 320/390/600/800/1280 بالعربية والإنجليزية.
- أي اختبار على جهاز فعلي (لم ولن أزعم ذلك).

---

## 10. مخاطر متبقية

1. الدالة غير منشورة ⇒ زر الحذف سيُرجع خطأ شبكة في التطبيق المبني حاليًا.
2. TTL: كلمة التأكيد «حذف» وقائية لكن الحذف نهائي؛ لا استرجاع.
3. تكرار البريد بعد الحذف قد يُنشئ ملفًا جديدًا (trigger) — يحتاج قرارًا منك لاحقًا.
4. كاش النواة المعطوب محليًا: أول `flutter test` على جهازك سيعيد بناءه (قد يستغرق دقائق).
5. اختبارات الشبكة تعتمد على ارتفاعات ثابتة؛ تغيير نمط البطاقة مستقبلًا قد يتطلب تحديث التوقعات.

---

## 11. خطوات يدوية مطلوبة في لوحة Supabase (لم أنفّذها ولن أنفّذها)

1. **Deploy الدالة:** `supabase functions deploy delete-my-account --project-ref qqfzbecwhewswkyxgebu` (أو من Dashboard ← Edge Functions ← Deploy). تأكد من `verify_jwt = true`.
2. **الأسرار:** تأكد من وجود `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` في بيئة الدالة (لا تضعها في التطبيق).
3. **Redirect URLs:** أضف `legalserviceapp://auth-callback` في Authentication ← URL Configuration.
4. **App Links:** انشر `assetlinks.json` صحيحًا قبل أي ادّعاء بروابط التطبيق.
5. **مفتاح الإصدار:** أنشئ keystore وأضف SHA-256 إلى `assetlinks.json`.
6. **مراقبة:** راقب سجلات الدالة عند أول استخدام حقيقي، وتأكد من عدم ظهور أي بيانات شخصية فيها.
