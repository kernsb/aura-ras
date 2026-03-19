import json
from django.shortcuts import render, redirect
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST
from .models import Computer, GlobalSettings
from .ssh_utils import sync_authorized_keys
from .jamf_api import JamfAPI

@csrf_exempt
@require_POST
def register_agent(request):
    try:
        data = json.loads(request.body)
        
        jssid = data.get('jssid')
        role = data.get('role')
        public_key = data.get('public_key')
        hostname = data.get('hostname')

        if not all([jssid, role, public_key, hostname]):
            return JsonResponse({'error': 'Missing required fields in payload'}, status=400)

        computer, created = Computer.objects.update_or_create(
            jssid=jssid,
            defaults={
                'role': role,
                'public_key': public_key,
                'hostname': hostname
            }
        )
        
        sync_authorized_keys()

        # Return the auto-incrementing ID back to the Mac for local storage
        return JsonResponse({
            'status': 'success', 
            'message': 'Registered successfully with AuraRAS',
            'id': computer.id,
            'ssh_port': computer.ssh_port,
            'vnc_port': computer.vnc_port
        }, status=200)

    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
@require_POST
def unregister_agent(request):
    """
    Called during the Swift agent's uninstall routine. 
    Deletes the endpoint from the database and immediately revokes its SSH key.
    """
    try:
        data = json.loads(request.body)
        jssid = data.get('jssid')

        if not jssid:
            return JsonResponse({'error': 'Missing jssid in payload'}, status=400)

        deleted_count, _ = Computer.objects.filter(jssid=jssid).delete()
        
        if deleted_count > 0:
            # Sync authorized keys to revoke SSH access immediately
            sync_authorized_keys()
            return JsonResponse({'status': 'success', 'message': 'Unregistered successfully'}, status=200)
        else:
            return JsonResponse({'status': 'not_found', 'message': 'Endpoint not found'}, status=404)

    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

def dashboard(request):
    """
    Renders the public-facing Bootstrap dashboard displaying all registered endpoints.
    """
    settings = GlobalSettings.load()
    laps_enabled = settings.jamf_laps_enabled
    
    if request.user.is_authenticated:
        profile = getattr(request.user, 'profile', None)
        role = profile.role if profile else 'Customer'
        theme = profile.theme if profile else 'auto'

        if role in ['Server Administrator', 'Desktop Administrator']:
            computers = Computer.objects.all().order_by('-last_checkin')
        else:
            computers = Computer.objects.filter(assigned_users=request.user).order_by('-last_checkin')
    else:
        computers = []
        role = None
        theme = 'auto'

    return render(request, 'api/dashboard.html', {
        'computers': computers,
        'user_role': role,
        'user_theme': theme,
        'laps_enabled': laps_enabled
    })

def server_settings(request):
    """
    Renders and processes the Settings page.
    Shows User Preferences to all authorized roles, and Global Settings to Server Admins.
    """
    if not request.user.is_authenticated:
        return redirect('oidc_authentication_init')
        
    profile = getattr(request.user, 'profile', None)
    role = profile.role if profile else 'Customer'
    
    # Allow all three valid roles to access the settings page
    if role not in ['Server Administrator', 'Desktop Administrator', 'Customer']:
        return redirect('dashboard')
        
    settings = GlobalSettings.load()
    success = False
    
    if request.method == 'POST':
        # 1. Save User Preferences (Available to everyone)
        if profile:
            theme = request.POST.get('theme')
            if theme in ['auto', 'light', 'dark']:
                profile.theme = theme
            
            timezone = request.POST.get('timezone')
            if timezone:
                profile.timezone = timezone
            profile.save()

        # 2. Save Global Settings (Server Admins ONLY)
        if role == 'Server Administrator':
            settings.jamf_url = request.POST.get('jamf_url')
            settings.jamf_client_id = request.POST.get('jamf_client_id')
            
            new_secret = request.POST.get('jamf_client_secret')
            if new_secret:
                settings.jamf_client_secret = new_secret
                
            settings.jamf_laps_enabled = request.POST.get('jamf_laps_enabled') == 'on'
            settings.prestage_laps_type = request.POST.get('prestage_laps_type', 'jamf')
            settings.macoslaps_ea_id = request.POST.get('macoslaps_ea_id', '')
            
            interval = request.POST.get('agent_checkin_interval_minutes')
            if interval and interval.isdigit():
                settings.agent_checkin_interval_minutes = int(interval)
                
            settings.save()
            
        success = True
        
    return render(request, 'api/settings.html', {
        'settings': settings, 
        'user_role': role,
        'profile': profile,
        'user_theme': profile.theme if profile else 'auto',
        'success': success
    })

# --- NEW LAPS AJAX ENDPOINTS ---

def laps_usernames(request, jssid):
    """Returns the expected usernames for the UI table"""
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    try:
        settings = GlobalSettings.load()
        api = JamfAPI(settings.jamf_url, settings.jamf_client_id, settings.jamf_client_secret)
        mgmt_id = api.get_management_id(jssid)
        
        # Fetch all available LAPS accounts
        accounts = api.get_laps_accounts(mgmt_id)
        jamf_user = None
        prestage_user = None
        
        for acc in accounts:
            if acc.get('userSource') == 'JMF':
                jamf_user = acc.get('username')
            elif acc.get('userSource') == 'MDM':
                # Only map this from Jamf if not overridden by macOSLAPS EA
                if settings.prestage_laps_type == 'jamf':
                    prestage_user = acc.get('username')

        # Override PreStage user if using macOSLAPS EA
        if settings.prestage_laps_type == 'macoslaps':
            if settings.macoslaps_ea_id:
                ea_val = api.get_extension_attribute(jssid, settings.macoslaps_ea_id)
                if ea_val:
                    prestage_user = "paeadmin"

        return JsonResponse({
            'status': 'success',
            'jamf_user': jamf_user,
            'prestage_user': prestage_user
        })
    except Exception as e:
        return JsonResponse({'status': 'error', 'message': str(e)}, status=500)

def laps_password(request, jssid, account_type):
    """Triggers Jamf API to pull the password for the specified account (CAUSES ROTATION)"""
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    settings = GlobalSettings.load()
    if not settings.jamf_laps_enabled:
        return JsonResponse({'status': 'error', 'message': 'LAPS is currently disabled globally.'}, status=400)
        
    try:
        api = JamfAPI(settings.jamf_url, settings.jamf_client_id, settings.jamf_client_secret)
        
        if account_type == 'jamf':
            mgmt_id = api.get_management_id(jssid)
            accounts = api.get_laps_accounts(mgmt_id)
            
            # Use 'username' instead of 'guid'
            username = next((acc['username'] for acc in accounts if acc.get('userSource') == 'JMF'), None)
            if not username:
                return JsonResponse({'status': 'error', 'message': 'Jamf Admin LAPS account not found.'}, status=404)
                
            password = api.get_laps_password(mgmt_id, username)
            return JsonResponse({'status': 'success', 'password': password})
            
        elif account_type == 'prestage':
            if settings.prestage_laps_type == 'macoslaps':
                if not settings.macoslaps_ea_id:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS EA ID is not configured.'}, status=400)
                password = api.get_extension_attribute(jssid, settings.macoslaps_ea_id)
                if not password:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS password was empty or not found.'}, status=404)
                return JsonResponse({'status': 'success', 'password': password})
            else:
                mgmt_id = api.get_management_id(jssid)
                accounts = api.get_laps_accounts(mgmt_id)
                
                # Use 'username' instead of 'guid'
                username = next((acc['username'] for acc in accounts if acc.get('userSource') == 'MDM'), None)
                if not username:
                    return JsonResponse({'status': 'error', 'message': 'PreStage Admin LAPS account not found.'}, status=404)
                    
                password = api.get_laps_password(mgmt_id, username)
                return JsonResponse({'status': 'success', 'password': password})
        else:
            return JsonResponse({'status': 'error', 'message': 'Invalid account type specified.'}, status=400)
            
    except Exception as e:
        return JsonResponse({'status': 'error', 'message': f"Jamf API Error: {str(e)}"}, status=500)
