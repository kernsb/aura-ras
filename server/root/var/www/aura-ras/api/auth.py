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
        user_info['roles'] = payload.get('roles', [])
        return user_info

    def filter_users_by_claims(self, claims):
        email = claims.get('preferred_username') or claims.get('email')
        if not email:
            return self.UserModel.objects.none()
        try:
            # Look up by 'email' since the 'username' is now just the short name
            return self.UserModel.objects.filter(email__iexact=email)
        except self.UserModel.DoesNotExist:
            return self.UserModel.objects.none()

    def create_user(self, claims):
        user = super(EntraIDOIDCAuthenticationBackend, self).create_user(claims)
        email = claims.get('preferred_username') or claims.get('email')
        
        user.first_name = claims.get('given_name', '')
        user.last_name = claims.get('family_name', '')
        user.email = email
        # Extract the short name (everything before the @)
        user.username = email.split('@')[0] if email else ''
        user.save()
        
        self._update_user_role(user, claims)
        return user

    def update_user(self, user, claims):
        # Update existing users so their username becomes the short name
        email = claims.get('preferred_username') or claims.get('email')
        if email:
            short_name = email.split('@')[0]
            if user.username != short_name:
                user.username = short_name
                user.save()

        # This ensures roles are updated on every login if changed in Entra ID!
        self._update_user_role(user, claims)
        return user

    def _update_user_role(self, user, claims):
        # Entra ID passes assigned roles in a 'roles' array list
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
            # Safe fallback: If they log in but have no roles assigned in Entra ID
            profile.role = 'Unassigned'
            user.is_staff = False
            user.is_superuser = False
            
        user.save()
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