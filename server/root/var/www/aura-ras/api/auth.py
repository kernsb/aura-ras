import logging
from mozilla_django_oidc.auth import OIDCAuthenticationBackend
from django.contrib.auth.signals import user_logged_in, user_logged_out
from django.dispatch import receiver
from api.models import UserProfile

# Fetch our dedicated event logger
aura_logger = logging.getLogger('aura_events')

class EntraIDOIDCAuthenticationBackend(OIDCAuthenticationBackend):
    def get_userinfo(self, access_token, id_token, payload):
        """
        Microsoft Entra ID does not include the 'roles' array in the standard 
        /userinfo endpoint response. We must explicitly inject it from the 
        initial ID token payload.
        """
        user_info = super().get_userinfo(access_token, id_token, payload)
        
        # Carry over all potential claims that might hold the username
        user_info['roles'] = payload.get('roles', [])
        user_info['upn'] = payload.get('upn')
        user_info['unique_name'] = payload.get('unique_name')
        user_info['preferred_username'] = payload.get('preferred_username')
        return user_info

    def _get_email(self, claims):
        # Entra ID is notoriously inconsistent. We check every possible username field.
        return claims.get('upn') or claims.get('unique_name') or claims.get('preferred_username') or claims.get('email') or ''

    def filter_users_by_claims(self, claims):
        email = self._get_email(claims)
        if not email:
            return self.UserModel.objects.none()
        try:
            return self.UserModel.objects.filter(email__iexact=email)
        except self.UserModel.DoesNotExist:
            return self.UserModel.objects.none()

    def create_user(self, claims):
        user = super(EntraIDOIDCAuthenticationBackend, self).create_user(claims)
        email = self._get_email(claims)
        
        user.first_name = claims.get('given_name', '')
        user.last_name = claims.get('family_name', '')
        user.email = email
        
        if email:
            user.username = email.split('@')[0]
            
        user.save()
        self._update_user_role(user, claims)
        return user

    def update_user(self, user, claims):
        email = self._get_email(claims)
        if email:
            short_name = email.split('@')[0]
            if user.username != short_name:
                user.username = short_name
                user.email = email
                user.save()

        self._update_user_role(user, claims)
        return user

    def _update_user_role(self, user, claims):
        entra_roles = claims.get('roles', [])
        profile, _ = UserProfile.objects.get_or_create(user=user)

        # Map the explicit Entra ID role values to our Django database roles
        if 'ServerAdmin' in entra_roles:
            profile.role = 'Server Administrator'
            user.is_staff = True
            user.is_superuser = True
        elif 'DesktopAdmin' in entra_roles:
            profile.role = 'Desktop Administrator'
            user.is_staff = False
            user.is_superuser = False
        elif 'Customer' in entra_roles:
            profile.role = 'Customer'
            user.is_staff = False
            user.is_superuser = False
        else:
            profile.role = 'Customer' # Safe fallback
            user.is_staff = False
            user.is_superuser = False
            
        user.save()
        
        # Explicitly save the profile to lock in the mapped role
        profile.save()

# ==============================================================================
# --- ENTERPRISE AUDIT LOGGING SIGNALS ---
# ==============================================================================

@receiver(user_logged_in)
def log_user_login(sender, request, user, **kwargs):
    ip = request.META.get('REMOTE_ADDR', 'Unknown IP')
    role = getattr(user.profile, 'role', 'Unknown') if hasattr(user, 'profile') else 'Unknown'
    aura_logger.info(f"ADMIN LOGIN | Admin: {user.username} | Role: {role} | Source IP: {ip}")

@receiver(user_logged_out)
def log_user_logout(sender, request, user, **kwargs):
    ip = request.META.get('REMOTE_ADDR', 'Unknown IP')
    username = user.username if user else 'Unknown'
    aura_logger.info(f"ADMIN LOGOUT | Admin: {username} | Source IP: {ip}")