# Phase 5 — جاهزية الإنتاج والنشر الفعلي على Supabase

**التاريخ:** 2026-11-05 · **المشروع:** `qqfzbecwhewswkyxgebu` («legal» · eu-west-1 · Postgres 17) · **آخر commit:** `c5a6173` (لا commit ولا push)

## الحالة النهائية

> ## ✅ COMPLETED AND VERIFIED ON LIVE SUPABASE
> الدالة منشورة وتعمل على المشروع الحيّ، والحذف الذاتي تحقق فعليًا على حساب اختباري، والسجلات القانونية سليمة، والترحيل مُطبَّق ومسجّل. القيود المتبقية موثّقة في §7 (لا يوجد منها ما يمنع التشغيل).

---

## 1. المخطط الحقيقي ومعرّف المشروع

**المعرّف مؤكَّد:** `qqfzbecwhewswkyxgebu` — الحالة `ACTIVE_HEALTHY`، Region `eu-west-1`، Postgres `17.11`.

**الجداول الحقيقية (21):** `users, lawyers, legal_categories, cases, bookings, booking_slots, availability, lawyer_weekly_schedules, lawyer_weekly_intervals, chats, chat_messages, favorites, reviews, plans, subscriptions, tasks, wallets, wallet_transactions, wallet_idempotency, earnings, notifications`.

**فروق مهمة عن افتراضات تقرير Phase 4 — كلها عولجت:**
| الافتراض القديم | الحقيقة على الحيّ | الأثر |
|---|---|---|
| لا توجد جداول محادثات | `chats` (بها `participants` نصّي و`participant_names` jsonb) و`chat_messages` | لا حذف لأي محادثة → تاريخ الطرف الآخر محفوظ |
| الجداول «التجارية» فقط | توجد كيانات قانونية فعلية: `cases`، `chats/chat_messages`، `reviews`، `availability`، `booking_slots` | فحصها كلها؛ لا شيء منها يُحذف |
| لا ملفات قانونية | دلو تخزين واحد `legal-documents` (٠ كائنات) | لا تنظيف تخزين مطلوب |
| لا عناوين/مستمعين | العنوان عمود داخل `users`، ولا جداول hearings/documents منفصلة | لا كيانات مخفية |
| — | **عيب حقيقي غير متوقع** في `public.is_admin()` | أُصلح بترحيل (§3) |

**المخزون الحقيقي قبل الاختبار:** 27 مستخدم Auth، 29 ملفًا (27 مرتبطًا)، 22 محاميًا، 7 حجوزات، 2 محادثة، 9 رسائل، 137 صف توفّر، 12 فتحة حجز، 0 كائنات تخزين.

**علاقات الحذف (31 مفتاحًا أجنبيًا):**
- `users.auth_user_id → auth.users` = **SET NULL** (المسار الوحيد المسموح).
- 12 علاقة `CASCADE` على `public.users` (bookings, chat_messages, favorites, reviews, wallets, subscriptions, notifications, tasks, earnings, wallet_transactions, wallet_idempotency, booking_slots) ⇒ **حذف صف الملف ممنوع نهائيًا**.
- `cases.user_id` = SET NULL، `lawyers.user_id` = SET NULL، `bookings.lawyer_id`/`cases.lawyer_id` = RESTRICT.

---

## 2. سلوك الحذف لكل دور (نهائي)

| الدور | السلوك | التحقق |
|---|---|---|
| **client / user** | حذف حساب Auth + تجهيل الملف (الاسم/البريد/الهاتف/الصورة/العنوان) مع **إبقاء الصف** ليظل تاريخ الأطراف الأخرى مرتبطًا | **حي: 200 `deleted:true`** |
| **lawyer** (له صف في `lawyers`) | **مرفوض 409 `LAWYER_PROFILE_REQUIRES_DEACTIVATION`**: «عطّل أو أعد تعيين ملفك العام قبل الحذف» — لأن `bookings.lawyer_id` و`cases.lawyer_id` بـ RESTRICT، والحذف سيمسّ حجوزات وقضايا العملاء | **حي: 409 والحساب سليم** |
| **admin** | **مرفوض 403 `ADMIN_ACCOUNT_PROTECTED`** — يُزال بواسطة مسؤول آخر | اختبار وحدة |
| **owner** | **مرفوض 403 `OWNER_ACCOUNT_PROTECTED`** + مشغّل `guard_owner_profile_delete` يمنع الحذف حتى عبر service role | اختبار وحدة + تعريف المشغّل |
| **بلا ملف تطبيق** | يُحذف حساب الدخول فقط بأمان | اختبار وحدة |

**بديل المحامي:** لا يوجد «إغلاق حساب» آلي في قواعد العمل الحالية؛ الرفض يوجّه صراحةً إلى تعطيل/إعادة تعيين الملف العام، وهو ما يملكه المسؤول عبر لوحة التحكم. لم أُخفِ ذلك ولم أُضف مسارًا جديدًا.

---

## 3. حالة نشر Edge Function

| البند | النتيجة |
|---|---|
| الحالة | **ACTIVE** · version 1 · `verify_jwt: true` · id `8feb5dfe-c63f-43b8-91f6-4a27a69a6930` |
| الرابط | `https://qqfzbecwhewswkyxgebu.supabase.co/functions/v1/delete-my-account` |
| المصدر | `supabase/functions/delete-my-account/` + **حزمة أحادية الملف** يولّدها `bundle.py` (`dist/index.ts`) لأن مدير الـ API يرفع ملفًا واحدًا |
| الأسرار | `SUPABASE_URL` و`SUPABASE_ANON_KEY` و`SUPABASE_SERVICE_ROLE_KEY` **موجودة مسبقًا** في بيئة الدوال (ظهرت كبصمات SHA-256 فقط، لم أقرأ أي قيمة) |
| المفتاح السرّي | لم يُستخدم في Flutter ولا في Git ولا في السجلات ولا في المحادثة |

**الضمانات المفحوصة في الكود والحيّ:**
1. الهدف هو `auth.uid()` من JWT متحقَّق منه داخل الدالة (بعد تحقّق البوابة).
2. أي معرّف في الجسم يخالف المستدعي ⇒ 403 قبل أي تغيير (مُختبر حيًّا).
3. `auth.admin.deleteUser(callerAuthId)` فقط.
4. الفشل بعد التجهيل يُرجع الحقول السابقة (rollback) — مُختبر بـ 20 اختبار Deno.
5. طلب مكرّر: الرمز صار باطلًا ⇒ 401 `INVALID_SESSION` (مُختبر حيًّا)، والمسار `alreadyDeleted` موجود لسباقات التزامن.
6. لا تُسجَّل بيانات شخصية، والاستجابات بلا رموز أو مفاتيح.

**العيب الذي كشفه الاختبار الحيّ وأُصلح (الأهم في هذه المرحلة):**
أول استدعاء حقيقي أرجع `503 PROFILE_ANONYMISATION_FAILED`. دالة تشخيص مؤقتة (حُذفت بعدها) أظهرت السبب:
```
42501: permission denied for function is_admin
```
`public.guard_user_identity_fields()` — يعمل على **كل** UPDATE في `public.users` — يستدعي `public.is_admin()` بلا توقف مبكر، وكانت صلاحية تنفيذها ممنوحة لـ `postgres` و`authenticated` فقط. أي كتابة من service_role على `public.users` كانت ستفشل (تجهيل الملف، وأي عملية إدارية أخرى، وكذلك إجراء الـ FK من خدمة Auth).

**الترحيل المطبَّق:** `20261105214842_grant_is_admin_execute_to_server_roles`
```sql
GRANT EXECUTE ON FUNCTION public.is_admin() TO service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO supabase_auth_admin;
```
مبرَّر الأمان: الدالة بلا وسائط ولا تقرأ جداول؛ تُرجع فقط هل JWT **المستدعي نفسه** مسؤول. لا تمنح وصول بيانات، ولا تغيّر منطق أي حماية، ولا تمسّ RLS. نسخة في الريبو: `supabase/migrations/20261105214842_grant_is_admin_execute_to_server_roles.sql`.

---

## 4. نتائج الاختبار الحيّ (أدلة حقيقية)

حساب اختباري مخصّص `phase5-selftest@deleted.invalid` (لا يخصّ أي مستخدم حقيقي)، وأُزيل بالكامل بعد الاختبار.

| # | الاختبار | الطلب | النتيجة الحقيقية |
|---|---|---|---|
| T1 | بلا ترويسة مصادقة | `POST` بلا Authorization | `401 UNAUTHORIZED_NO_AUTH_HEADER` |
| T2 | JWT غير صالح | `Bearer invalid.token.value` | `401 UNAUTHORIZED_INVALID_JWT_FORMAT` |
| T3 | طريقة غير مسموحة | `GET` | `405 METHOD_NOT_ALLOWED` |
| T4 | جسم يسمّي مستخدمًا آخر | `{"user_id":"0000…dead"}` | `403 TARGET_NOT_ALLOWED` ولم يتغيّر شيء |
| T5 | حذف ذاتي حقيقي | `POST` بجسم فارغ | `200 {"deleted":true,"profileRetained":true,"profileAnonymised":true,"historyRetained":true}` |
| T6 | إعادة الطلب بالرمز القديم | نفس الرمز | `401 INVALID_SESSION` (لا 500، لا حذف ثانٍ) |
| T7 | دخول بالبريد المجهَّل | password grant | `400 invalid_credentials` |
| T8 | دخول بالبريد الأصلي | password grant | `400 invalid_credentials` |
| T9 | محامٍ يحاول الحذف | JWT محامٍ نشط | `409 LAWYER_PROFILE_REQUIRES_DEACTIVATION` |
| T10 | حساب المحامي بعد الرفض | `GET /auth/v1/user` | `200` — الحساب سليم تمامًا |

**أثر الحذف على البيانات (قياس قبل/بعد):**

| العنصر | قبل | بعد | الحكم |
|---|---|---|---|
| `auth.users` | 28 | 27 | حُذف الحساب الاختباري فقط ✓ |
| `public.users` | 30 | 30 | الصف محفوظ ✓ |
| الحقول الشخصية | name/email/phone/avatar/address | `Deleted account` / `deleted+…@deleted.invalid` / فارغ/فارغ/فارغ | تجهيل كامل، `id` و`role` سليمان ✓ |
| `auth_user_id` | مرتبط | `NULL` | فُصل عبر قيد الـ FK ✓ |
| `lawyers` | 22 | 22 | ✓ |
| `bookings` | 7 | 7 | ✓ |
| `chats` / `chat_messages` | 2 / 9 | 2 / 9 | ✓ |
| `availability` / `booking_slots` | 137 / 12 | 137 / 12 | ✓ |
| `storage.objects` | 0 | 0 | ✓ |

**التنظيف:** حُذف الحسابان الاختباريان (عميل + محامٍ) وصف `lawyers` المؤقت ودالة التشخيص؛ وعادت القاعدة إلى خط الأساس تمامًا (27/29/22/7/2/9/137/12).

---

## 5. التحقق من احتفاظ البيانات القانونية

- لا يُحذف صف `public.users` أبدًا ⇒ لا تُفعَّل أي `CASCADE` على 12 علاقة.
- القضايا (`cases`) والحجوزات (`bookings`) والمحادثات (`chats`) والرسائل (`chat_messages`) والتقييمات (`reviews`) والجداول المالية: **لم يتغيّر أي صف** (مثبت بالقياس أعلاه).
- الملف المجهَّل يبقي الربط قائمًا (`cases.user_id`، `bookings.user_id`، `chat_messages.sender_id`) فيظل الطرف الآخر يرى تاريخه.
- دلو `legal-documents` فارغ ⇒ لا حاجة لتنظيف كائنات؛ وعند وجودها لاحقًا يجب تنظيف ما يملكه المستدعي فقط (موثّق كمخاطرة).

---

## 6. التحقق من شبكة الرئيسية (Feature 2)

لم تُمسّ. `flutter test test/home_restore_layout_test.dart` ⇒ **`All tests passed!` 18/18** (بعد إعادة تثبيت SDK في هذه الجلسة).

---

## 7. القيود والمخاطر المتبقية

| البند | الحالة |
|---|---|
| **`flutter test` الكامل في عملية واحدة** | لم يكتمل: يتوقف المُشغّل دائمًا عند الملف الـ13 (`loading home_restore_layout_test.dart`) رغم توفّر 1.3 GB ذاكرة — قيد أدوات لا فشل اختبار. **لكن التغطية كاملة عبر دفعات (31/31 ملفًا): 119 + 234 + 17 + 18 = 388 اختبارًا، كلها ناجحة** |
| **بناء APK (debug)** | **لم يكتمل**: مشروع `android/gradle.properties` يضبط `-Xmx8G` على جهاز بـ2 GB ⇒ قُتل Gradle daemon مرتين؛ جرّبت تخفيضه إلى 1.2 GB ونجح التجاوز لكن الـdaemon قُتل أيضًا. أُعيد الملف لحالته الأصلية |
| **`.git`** | بيانات git لم تُحفظ في لقطة هذه البيئة (`.git` مستثنى)، فلا يمكن إظهار `git status`؛ شجرة العمل سليمة (132 ملف Dart) ولم أُنشئ أي commit |
| app links / `assetlinks.json` | لا يزال غير منشور — لا علاقة له بالحذف |
| mignature keystore للإصدار | غير موجود |
| **تسريب محتمل في أدوات لوحة التحكم** | `get_auth_config` أعاد **كلمة مرور SMTP نصًّا صريحًا**، و`list_api_keys` أعاد **قيمة service_role كاملة**. لم أنسخها هنا ولم أستخدم المفتاح، لكن يُستحسن **تدوير** مفتاح Brevo SMTP ومفاتيح API للمشروع، وتقييد من يملك وصولًا للمُوصِّل |
| تكرار البريد بعد الحذف | `trg_auth_users_link_migrated` قد يُنشئ ملفًا جديدًا لبريد مُعاد استخدامه (الفهرس غير فريد) |
| محامون | يحتاجون مسار تعطيل/إغلاق في اللوحة — غير موجود كإجراء ذاتي |
| اختبار جهاز فعلي | لم يُجرَ ولن أزعمه |

### أوامر نُفِّذت ونتائجها الحقيقية
| الأمر | النتيجة |
|---|---|
| `deno test supabase/functions/delete-my-account/` | **20 passed / 0 failed** |
| `flutter analyze lib test` | **27 ملاحظة (23 info + 4 تحذير)، 0 أخطاء** — كلها في ملفات سابقة التعديل، لا شيء في ملفات هذه الميزة |
| `flutter test test/account_deletion_controller_test.dart test/account_deletion_screen_test.dart` | **17/17** |
| `flutter test test/home_restore_layout_test.dart` | **18/18** |
| `flutter test` (كامل، عملية واحدة) | توقّف عند 119 اختبارًا / الملف 13 — غير مكتمل |
| `flutter test` (بقية الملفات، `--concurrency=1`) | **234/234 نجحت** |
| `flutter build apk --debug` | **فشل**: Gradle daemon قُتل (ذاكرة) |
| استدعاءات الدالة الحيّة T1–T10 | كما في §4 |

### عن التفاوت في أعداد الاختبارات (طلب صريح)
كان تقرير Phase 4 يذكر «13 نجحت / 5 فشلت» ثم «17». السبب: الملف كان واحدًا ثم قُسِّم إلى `account_deletion_controller_test.dart` (10) + `account_deletion_screen_test.dart` (7) = **17**، وإلى جانبه **20** اختبار Deno. الأعداد الآن مطابقة للملفات ومؤكَّدة بالتشغيل، لا بالتقدير.

---

## أين صار كل شيء

- `supabase/functions/delete-my-account/{index.ts, account_deletion.ts, account_deletion_test.ts}` — المصدر.
- `supabase/functions/delete-my-account/bundle.py` + `dist/index.ts` — حزمة النشر المطابقة لما نُشر.
- `supabase/migrations/20261105214842_grant_is_admin_execute_to_server_roles.sql` — الترحيل المطبَّق.
- `lib/views/profile/delete_account.dart`, `lib/state/session_controller.dart`, `lib/services/api_client.dart`, `lib/views/profile/profile_screen.dart` — تطبيق Flutter.
- `lib/views/home/homescreen.dart` — شبكة العمودين (بلا تغيير).
