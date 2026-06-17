"""
Django settings for aura_ras_server project.
"""

import os
from pathlib import Path

# Build paths inside the project like this: BASE_DIR / 'subdir'.
BASE_DIR = Path(__file__).resolve().parent.parent

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = 'your-django-secret-key'

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = False

# Add your server's IP or Domain Name here
ALLOWED_HOSTS = ['*'] 

# Application definition
INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    
    # Third-party OIDC app for Entra ID Authentication
    'mozilla_django_oidc', 
    
    # AuraRAS Core App
    'api',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

# Authentication Backends (Crucial for Entra ID integration)
AUTHENTICATION_BACKENDS = (
    'mozilla_django_oidc.auth.OIDCAuthenticationBackend',
    'django.contrib.auth.backends.ModelBackend',
)

ROOT_URLCONF = 'aura_ras_server.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [os.path.join(BASE_DIR, 'templates')],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'aura_ras_server.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'auraras_db',
        'USER': 'auraras_user',
        'PASSWORD': r'MCD2pk4FG^t,', 
        'HOST': 'ldvdbamydv09.it.purdue.edu',
        'PORT': '3306',
        'OPTIONS': {
            'ssl': {'ca': '/etc/pki/tls/certs/ca-bundle.crt'},
        }
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator',},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator',},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'America/Indiana/Indianapolis'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'static')
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# --- ENTRA ID (OIDC) CONFIGURATION ---
OIDC_RP_CLIENT_ID = 'your-entra-id-client-id'
OIDC_RP_CLIENT_SECRET = 'your-entra-id-client-secret'
OIDC_RP_SIGN_ALGO = 'RS256'
OIDC_OP_AUTHORIZATION_ENDPOINT = 'https://login.microsoftonline.com/your-tenant-id/oauth2/v2.0/authorize'
OIDC_OP_TOKEN_ENDPOINT = 'https://login.microsoftonline.com/your-tenant-id/oauth2/v2.0/token'
OIDC_OP_USER_ENDPOINT = 'https://graph.microsoft.com/oidc/userinfo'
OIDC_OP_JWKS_ENDPOINT = 'https://login.microsoftonline.com/your-tenant-id/discovery/v2.0/keys'
LOGIN_REDIRECT_URL = '/'
LOGOUT_REDIRECT_URL = '/'

# --- AURA RAS SPECIFIC SECRETS & CONFIG ---
AURA_API_SECRET = "YourSecureRandomStringHere"


# ==============================================================================
# --- APPLICATION LOGGING CONFIGURATION ---
# ==============================================================================
# Attempts to fetch the secure APP_LOG_DIR injected by the deploy script.
# Fallback to a local /logs folder if running in a dev environment.
try:
    LOG_DIR = APP_LOG_DIR
except NameError:
    LOG_DIR = os.path.join(BASE_DIR, 'logs')

os.makedirs(LOG_DIR, exist_ok=True)

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'detailed': {
            'format': '[{asctime}] {levelname} | {message}',
            'style': '{',
            'datefmt': '%Y-%m-%d %H:%M:%S',
        },
    },
    'handlers': {
        'aura_file_handler': {
            'level': 'INFO',
            'class': 'logging.handlers.TimedRotatingFileHandler',
            'filename': os.path.join(LOG_DIR, 'aura_events.log'),
            'when': 'midnight',   # Rotate daily at midnight
            'interval': 1,        # 1 day interval
            'backupCount': 30,    # Keep logs for 30 days
            'formatter': 'detailed',
        },
    },
    'loggers': {
        'aura_events': {
            'handlers': ['aura_file_handler'],
            'level': 'INFO',
            'propagate': False,
        },
    },
}