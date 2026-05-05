import 'package:avatar_plus/avatar_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/screens/chat_screen.dart';

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('ChatScreen', () {
    testWidgets('affiche empty state si aucun message', (tester) async {
      final firestore = FakeFirebaseFirestore();
      final authController = AuthController(
        firebaseAuth: MockFirebaseAuth(signedIn: false),
        firestore: firestore,
      );

      await tester.pumpWidget(
        _buildTestApp(
          ChatScreen(
            firestore: firestore,
            authController: authController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Be the first to write!'), findsOneWidget);
    });

    testWidgets('input désactivé si non authentifié', (tester) async {
      final firestore = FakeFirebaseFirestore();
      final authController = AuthController(
        firebaseAuth: MockFirebaseAuth(signedIn: false),
        firestore: firestore,
      );

      await tester.pumpWidget(
        _buildTestApp(
          ChatScreen(
            firestore: firestore,
            authController: authController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in to participate'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.send_rounded), findsNothing);
    });

    testWidgets(
      'admin tap avatar opens profile sheet with moderation actions',
      (tester) async {
        final firestore = FakeFirebaseFirestore();
        final authController = AuthController(
          firebaseAuth: MockFirebaseAuth(
            mockUser: MockUser(uid: 'admin_1', email: 'admin@tuni.tn'),
            signedIn: true,
          ),
          firestore: firestore,
        );

        await firestore.collection('users').doc('u_1').set({
          'uid': 'u_1',
          'username': 'community_user',
          'email': 'community@tuni.tn',
          'avatarId': 'avatar-01',
          'status': 'active',
        });

        await firestore.collection('community_messages').doc('m_1').set({
          'uid': 'u_1',
          'username': 'community_user',
          'avatarId': 'avatar-01',
          'text': 'hello from community',
          'timestamp': Timestamp.now(),
        });

        await tester.pumpWidget(
          _buildTestApp(
            ChatScreen(
              firestore: firestore,
              authController: authController,
              isAdminMode: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(AvatarPlus).first);
        await tester.pumpAndSettle();

        expect(find.text('community_user'), findsAtLeastNWidgets(1));
        expect(find.text('community@tuni.tn'), findsOneWidget);
        expect(find.text('Ban for 3 days'), findsOneWidget);
        expect(find.text('Ban for 7 days'), findsOneWidget);
        expect(find.text('Block permanently'), findsOneWidget);
        expect(find.text('Unblock user'), findsOneWidget);
      },
    );
  });
}
