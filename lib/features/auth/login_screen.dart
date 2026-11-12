import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants.dart';

// ─────────────────────────────────────────────────────────────
// Secure storage for Cognito session tokens
// ─────────────────────────────────────────────────────────────
class SecureCognitoStorage extends CognitoStorage {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future getItem(String key) async => _storage.read(key: key);

  @override
  Future setItem(String key, value) async {
    await _storage.write(key: key, value: value?.toString());
    return value;
  }

  @override
  Future removeItem(String key) async {
    final old = await _storage.read(key: key);
    await _storage.delete(key: key);
    return old;
  }

  @override
  Future<void> clear() async => _storage.deleteAll();
}

// ─────────────────────────────────────────────────────────────
// Auth state + notifier
// ─────────────────────────────────────────────────────────────
enum AuthStatus { unknown, unauthenticated, authenticated }

class AuthState {
  final AuthStatus status;
  final String? email;

  const AuthState({required this.status, this.email});
}

class AuthNotifier extends Notifier<AuthState> {
  late final CognitoUserPool _pool;

  @override
  AuthState build() {
    _pool = CognitoUserPool(
      AppConstants.userPoolId,
      AppConstants.userPoolClientId,
      storage: SecureCognitoStorage(),
    );
    Future.microtask(_restoreSession);
    return const AuthState(status: AuthStatus.unknown);
  }

  Future<void> _restoreSession() async {
    try {
      final user = await _pool.getCurrentUser();
      final session = await user?.getSession();
      if (user != null && session != null && session.isValid()) {
        state = AuthState(
          status: AuthStatus.authenticated,
          email: user.username,
        );
        return;
      }
    } catch (_) {
      // fall through to unauthenticated
    }
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Returns null on success, otherwise a user-friendly error message.
  Future<String?> login(String email, String password) async {
    final cleanEmail = email.trim();
    final user = CognitoUser(cleanEmail, _pool, storage: _pool.storage);
    final details = AuthenticationDetails(
      username: cleanEmail,
      password: password,
    );

    try {
      final session = await user.authenticateUser(details);
      if (session == null || !session.isValid()) {
        return 'লগইন ব্যর্থ হয়েছে। আবার চেষ্টা করুন।';
      }
      state = AuthState(status: AuthStatus.authenticated, email: cleanEmail);
      return null;
    } on CognitoUserNewPasswordRequiredException {
      return 'নতুন পাসওয়ার্ড সেট করা প্রয়োজন। (Cognito Console থেকে পাসওয়ার্ড সেট করুন)';
    } on CognitoUserMfaRequiredException {
      return 'এই অ্যাকাউন্টে MFA চালু আছে, যা এখনো সাপোর্টেড নয়।';
    } on CognitoUserConfirmationNecessaryException {
      return 'অ্যাকাউন্ট এখনো কনফার্ম করা হয়নি।';
    } on CognitoClientException catch (e) {
      switch (e.code) {
        case 'NotAuthorizedException':
          return 'ইমেইল বা পাসওয়ার্ড ভুল।';
        case 'UserNotFoundException':
          return 'এই ইমেইলে কোনো অ্যাকাউন্ট পাওয়া যায়নি।';
        case 'UserNotConfirmedException':
          return 'অ্যাকাউন্ট এখনো কনফার্ম করা হয়নি।';
        case 'NetworkError':
          return 'ইন্টারনেট সংযোগ চেক করুন।';
        default:
          return e.message ?? 'লগইনে সমস্যা হয়েছে (${e.code})';
      }
    } catch (e) {
      return 'অপ্রত্যাশিত সমস্যা: $e';
    }
  }

  Future<void> logout() async {
    try {
      final user = await _pool.getCurrentUser();
      await user?.signOut();
    } catch (_) {}
    await _pool.storage?.clear();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// ID token (JWT) for API Gateway Authorization header.
  /// Auto-refreshes if expired. Returns null if not logged in.
  Future<String?> getIdToken() async {
    try {
      final user = await _pool.getCurrentUser();
      final session = await user?.getSession();
      return session?.getIdToken().getJwtToken();
    } catch (_) {
      return null;
    }
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

// ─────────────────────────────────────────────────────────────
// Login screen
// ─────────────────────────────────────────────────────────────
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _error = null;
    });

    final err = await ref
        .read(authProvider.notifier)
        .login(_emailCtrl.text, _passCtrl.text);

    if (!mounted) return;
    // On success the router redirect moves us to the home screen.
    setState(() {
      _loading = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.storefront_rounded, size: 72, color: cs.primary),
                    const SizedBox(height: 16),
                    Text(
                      AppConstants.appName,
                      textAlign: TextAlign.center,
                      style: tt.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Owner Login',
                      textAlign: TextAlign.center,
                      style: tt.bodyLarge?.copyWith(color: cs.outline),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      enabled: !_loading,
                      decoration: const InputDecoration(
                        labelText: 'ইমেইল',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return 'ইমেইল দিন';
                        if (!s.contains('@') || !s.contains('.')) {
                          return 'সঠিক ইমেইল দিন';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passCtrl,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      enabled: !_loading,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'পাসওয়ার্ড',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'পাসওয়ার্ড দিন' : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: cs.onErrorContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(color: cs.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _loading ? null : _submit,
                        child: _loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Text('লগইন',
                                style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
