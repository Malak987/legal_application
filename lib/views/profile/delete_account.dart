import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../authentication/login_screen.dart';

/// Self-service account deletion screen.
///
/// The flow is deliberately cautious: the user reads what will be deleted,
/// types the confirmation word, and only then can the destructive button be
/// pressed. The actual double-submission guard is
/// `SessionController.isDeletingAccount` — while a deletion is in flight the
/// button is disabled and a second request cannot start.
///
/// The wording must describe what the backend actually does. Deletion is
/// COMPLETE, not anonymisation: `public.users.auth_user_id` cascades from
/// `auth.users`, and every dependent row (cases, bookings, bookings slots,
/// reviews, tasks, notifications, wallet, favorites) is removed by
/// `ON DELETE CASCADE`, while `private.purge_user_chats_before_delete()`
/// removes the caller's chats and their messages. Do not reintroduce
/// "records are kept anonymously" copy here.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  /// The word the user must type. Kept in Arabic because the screen is Arabic.
  static const String confirmationWord = 'حذف';

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final TextEditingController _confirmation = TextEditingController();
  String? _error;
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _confirmation.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _confirmation.removeListener(_onTextChanged);
    _confirmation.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    setState(() {
      // Clear a stale error as soon as the user edits the confirmation so the
      // message never outlives the state it described.
      if (_error != null) _error = null;
    });
  }

  bool get _canDelete =>
      _confirmation.text.trim() == DeleteAccountScreen.confirmationWord;

  Future<void> _confirmAndDelete() async {
    final session = SessionScope.read(context);
    final navigator = Navigator.of(context);
    _attempted = true;

    // Second, explicit confirmation. Nothing destructive happens on the first
    // tap, and the dialog itself restates the consequences.
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد الحذف النهائي'),
          content: const SingleChildScrollView(
            child: Text(
              'سيتم حذف حسابك وجميع بياناتك نهائيًا، ولا يمكن التراجع عن هذا الإجراء.\n\n'
              'يشمل ذلك بياناتك الشخصية، وقضاياك، وحجوزاتك، ومحادثاتك، ومراجعاتك، '
              'وملفاتك المخزّنة. لن يُحتفظ بأي نسخة منها بعد الحذف.',
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('delete-account-dialog-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            TextButton(
              key: const ValueKey('delete-account-dialog-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text('حذف الحساب نهائيًا'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _error = null);
    bool deleted;
    try {
      deleted = await session.deleteAccount();
    } catch (_) {
      // `deleteAccount` reports failures through its return value and
      // `session.error`; reaching here means the call itself threw.
      deleted = false;
    }
    if (!mounted) return;

    if (!deleted) {
      setState(() {
        _error =
            session.error ??
            'تعذر حذف الحساب. لم يتم حذف أي بيانات. حاول مرة أخرى.';
      });
      return;
    }

    // Confirmed deletion: replace the whole stack so no authenticated route —
    // and no stale session — can be reached with the Back gesture.
    navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    ScaffoldMessenger.of(navigator.context).showSnackBar(
      const SnackBar(content: Text('تم حذف حسابك بنجاح.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final busy = session.isDeletingAccount;
    final profile = session.profile;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.bgColor,
        body: SafeArea(
          child: AbsorbPointer(
            // While the request is in flight every control is inert, so a
            // double tap cannot queue a second deletion.
            absorbing: busy,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
              children: [
                const CustomAppBar(text: 'حذف الحساب', text1: ''),
                const SizedBox(height: 16),
                Card(
                  color: Colors.white,
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: Colors.red.shade700),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'إجراء نهائي لا يمكن التراجع عنه',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _bullet('سيتم حذف حساب الدخول الخاص بك، فلن تتمكن من '
                            'تسجيل الدخول بهذا البريد مرة أخرى.'),
                        _bullet('سيتم محو بياناتك الشخصية: الاسم، البريد الإلكتروني، '
                            'رقم الهاتف، العنوان، والصورة.'),
                        _bullet('سيتم حذف تفضيلاتك وإشعاراتك ومراجعاتك وحجوزاتك '
                            'المرتبطة بحسابك.'),
                        _bullet('سيتم حذف قضاياك وحجوزاتك ومحادثاتك ومراجعاتك '
                            'وملفاتك المخزّنة بالكامل، دون الاحتفاظ بأي نسخة منها.'),
                        _bullet('لا يمكن استعادة الحساب أو محتواه بعد الحذف.'),
                        if (profile != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.bgColor,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'الحساب الحالي: ${profile.email}',
                              textDirection: TextDirection.ltr,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.text2Color,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: Colors.white,
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'للمتابعة، اكتب كلمة «${DeleteAccountScreen.confirmationWord}» '
                          'في الحقل التالي:',
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('delete-account-confirmation'),
                          controller: _confirmation,
                          enabled: !busy,
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                            hintText: DeleteAccountScreen.confirmationWord,
                            border: const OutlineInputBorder(),
                            errorText:
                                _attempted && !_canDelete
                                    ? 'اكتب كلمة «${DeleteAccountScreen.confirmationWord}» للمتابعة'
                                    : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('delete-account-error'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 13, color: Colors.red.shade800),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    key: const ValueKey('delete-account-submit'),
                    onPressed: busy || !_canDelete ? null : _confirmAndDelete,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade400,
                      disabledForegroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: busy
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              SizedBox(width: 12),
                              Text('جارٍ حذف الحساب…'),
                            ],
                          )
                        : const Text(
                            'حذف الحساب نهائيًا',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(context).maybePop(),
                  child: const Text('إلغاء والعودة'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, left: 8),
            child: Icon(Icons.circle, size: 6, color: AppColors.text3Color),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
