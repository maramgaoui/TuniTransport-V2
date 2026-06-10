import 'package:flutter/material.dart';

class ValidationUtils {
  static String? validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email est requis';
    }
    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
    if (!emailRegex.hasMatch(value)) {
      return 'Format d\'email invalide';
    }
    return null;
  }

  static bool isEmailValid(String? value) {
    if (value == null || value.isEmpty) return false;
    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
    return emailRegex.hasMatch(value);
  }

  static PasswordStrength validatePasswordStrength(String? value) {
    if (value == null || value.isEmpty) {
      return PasswordStrength.empty;
    }

    int strength = 0;

    if (value.length >= 6) strength++;
    if (value.length >= 8) strength++;
    if (value.length >= 12) strength++;

    if (value.contains(RegExp(r'[A-Z]'))) strength++;
    if (value.contains(RegExp(r'[a-z]'))) strength++;
    if (value.contains(RegExp(r'[0-9]'))) strength++;
    if (value.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) strength++;

    if (strength <= 1) {
      return PasswordStrength.weak;
    } else if (strength <= 3) {
      return PasswordStrength.fair;
    } else if (strength <= 5) {
      return PasswordStrength.good;
    } else {
      return PasswordStrength.strong;
    }
  }

  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Le mot de passe est requis';
    }
    if (value.length < 6) {
      return 'Le mot de passe doit contenir au moins 6 caractères';
    }
    final strength = validatePasswordStrength(value);
    if (strength == PasswordStrength.weak) {
      return 'Le mot de passe est trop faible';
    }
    return null;
  }

  // Accented characters (À-ÿ), hyphens, and apostrophes are allowed for French names.
  static String? validateName(String? value, String fieldName) {
    if (value == null || value.isEmpty) {
      return '$fieldName est requis';
    }
    final nameRegex = RegExp(r"^[a-zA-ZÀ-ÿ\s\-']+$");
    if (!nameRegex.hasMatch(value)) {
      return '$fieldName ne peut contenir que des lettres';
    }
    if (value.length < 2) {
      return '$fieldName doit contenir au moins 2 caractères';
    }
    return null;
  }

  static bool isNameValid(String? value) {
    if (value == null || value.isEmpty) return false;
    final nameRegex = RegExp(r"^[a-zA-ZÀ-ÿ\s\-']+$");
    return nameRegex.hasMatch(value) && value.length >= 2;
  }

  static String? validateUsername(String? value) {
    if (value == null || value.isEmpty) {
      return 'Le nom d\'utilisateur est requis';
    }
    final usernameRegex = RegExp(r'^[a-zA-Z0-9_\-]+$');
    if (!usernameRegex.hasMatch(value)) {
      return 'Le nom d\'utilisateur ne peut contenir que des lettres, des chiffres, _ et -';
    }
    if (value.length < 3) {
      return 'Le nom d\'utilisateur doit contenir au moins 3 caractères';
    }
    if (value.length > 20) {
      return 'Le nom d\'utilisateur doit contenir au maximum 20 caractères';
    }
    return null;
  }

  static bool isUsernameValid(String? value) {
    if (value == null || value.isEmpty) return false;
    final usernameRegex = RegExp(r'^[a-zA-Z0-9_\-]+$');
    return usernameRegex.hasMatch(value) && value.length >= 3 && value.length <= 20;
  }

  // Matricule format: 4 letters followed by 2 digits, e.g. "ABCD12".
  static final RegExp _matriculeRegex = RegExp(r'^[A-Za-z]{4}[0-9]{2}$');

  static String? validateMatricule(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return 'Le matricule est requis';
    }
    if (!_matriculeRegex.hasMatch(trimmed)) {
      return 'Le matricule doit contenir 4 lettres suivies de 2 chiffres (ex: ABCD12)';
    }
    return null;
  }

  static bool isMatriculeValid(String? value) {
    final trimmed = value?.trim() ?? '';
    return _matriculeRegex.hasMatch(trimmed);
  }

  static String? validateConfirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) {
      return 'Veuillez confirmer votre mot de passe';
    }
    if (value != password) {
      return 'Les mots de passe ne correspondent pas';
    }
    return null;
  }

  static bool doesPasswordMatch(String? confirmPassword, String password) {
    if (confirmPassword == null || confirmPassword.isEmpty) return false;
    return confirmPassword == password;
  }
}

enum PasswordStrength {
  empty,
  weak,
  fair,
  good,
  strong,
}

extension PasswordStrengthExtension on PasswordStrength {
  String get label {
    switch (this) {
      case PasswordStrength.empty:
        return 'Pas de mot de passe';
      case PasswordStrength.weak:
        return 'Faible';
      case PasswordStrength.fair:
        return 'Moyen';
      case PasswordStrength.good:
        return 'Bon';
      case PasswordStrength.strong:
        return 'Fort';
    }
  }

  Color get color {
    switch (this) {
      case PasswordStrength.empty:
        return Colors.grey;
      case PasswordStrength.weak:
        return Colors.red;
      case PasswordStrength.fair:
        return Colors.orange;
      case PasswordStrength.good:
        return Colors.amber;
      case PasswordStrength.strong:
        return Colors.green;
    }
  }

  int get percentage {
    switch (this) {
      case PasswordStrength.empty:
        return 0;
      case PasswordStrength.weak:
        return 25;
      case PasswordStrength.fair:
        return 50;
      case PasswordStrength.good:
        return 75;
      case PasswordStrength.strong:
        return 100;
    }
  }
}
