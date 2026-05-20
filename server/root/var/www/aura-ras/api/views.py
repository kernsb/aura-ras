import json
import socket
import subprocess
import logging
from functools import wraps
from datetime import timedelta

from django.conf import settings
from django.shortcuts import render, redirect
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST
from django.contrib.auth.models import User
from django.contrib.auth.decorators import login_required

from .models import Computer, GlobalSettings, UserProfile
from .ssh_utils import sync_authorized_keys
from .jamf_api import JamfAPI

# Initialize the standard Python logger
logger = logging.getLogger(__name__)

# --- SECURITY DECORATOR ---
def require_api_secret(view_func):
    """
    Decorator to ensure incoming API requests contain the correct Pre-Shared Key.
    """
    @wraps(view_func)
    def _wrapped_view(request, *args, **kwargs):
        expected_secret = getattr(settings, 'AURA_API_SECRET', None)
        
        if not expected_secret:
            logger.error("SECURITY FAULT: AURA_API_SECRET is not configured in aura_ras_server/settings.py!")
            return JsonResponse({'error': 'Server configuration error'}, status=500)
        
        auth_header = request.headers.get('Authorization', '')
        # Defensively strip whitespace, though Apache WSGI stripping the header entirely is the main culprit
        if expected_secret and auth_header.strip() != f"Bearer {expected_secret.strip()}":
            client_ip = request.META.get('REMOTE_ADDR', 'Unknown IP')
            logger.warning(f"Unauthorized API access attempt from {client_ip}. Invalid Bearer token.")
            return JsonResponse({'error': 'Unauthorized'}, status=401)
            
        return view_func(request, *args, **kwargs)
    return _wrapped_view

# --- SWIFT AGENT API ENDPOINTS ---

@csrf_exempt
@require_POST
@require_api_secret
def register_agent(request):
    try:
        data = json.loads(request.body)
        
        jssid = data.get('jssid')
        role = data.get('role')
        public_key = data.get('public_key')
        hostname = data.get('hostname')

        if not all([jssid, role, public_key, hostname]):
            logger.warning("Agent registration failed: Missing required fields in payload.")
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

        logger.info(f"Agent successfully registered: {hostname} (JSSID: {jssid})")
        return JsonResponse({
            'status': 'success', 
            'message': 'Registered successfully with AuraRAS',
            'id': computer.id,
            'ssh_port': computer.ssh_port,
            'vnc_port': computer.vnc_port
        }, status=200)

    except json.JSONDecodeError:
        logger.warning(f"Invalid JSON format received at register_agent from {request.META.get('REMOTE_ADDR')}")
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        logger.error(f"Critical error in register_agent: {str(e)}", exc_info=True)
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
@require_POST
@require_api_secret
def unregister_agent(request):
    try:
        data = json.loads(request.body)
        jssid = data.get('jssid')

        if not jssid:
            return JsonResponse({'error': 'Missing jssid in payload'}, status=400)

        deleted_count, _ = Computer.objects.filter(jssid=jssid).delete()
        
        if deleted_count > 0:
            sync_authorized_keys()
            logger.info(f"Agent successfully unregistered and keys revoked for JSSID: {jssid}")
            return JsonResponse({'status': 'success', 'message': 'Unregistered successfully'}, status=200)
        else:
            logger.warning(f"Unregister attempt failed: Endpoint JSSID {jssid} not found.")
            return JsonResponse({'status': 'not_found', 'message': 'Endpoint not found'}, status=404)

    except json.JSONDecodeError:
        logger.warning(f"Invalid JSON format received at unregister_agent from {request.META.get('REMOTE_ADDR')}")
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        logger.error(f"Critical error in unregister_agent: {str(e)}", exc_info=True)
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
@require_POST
@require_api_secret
def checkin_agent(request):
    try:
        data = json.loads(request.body)
        jssid = data.get('jssid')

        if not jssid:
            return JsonResponse({'error': 'Missing jssid in payload'}, status=400)

        computer = Computer.objects.filter(jssid=jssid).first()
        if not computer:
            logger.warning(f"Check-in rejected: Computer with JSSID {jssid} not found. Needs registration.")
            return JsonResponse({'error': 'Computer not found. Please register first.'}, status=404)

        if 'hostname' in data: computer.hostname = data['hostname']
        if 'serial_number' in data: computer.serial_number = data['serial_number']
        if 'last_user' in data: computer.last_user = data['last_user']
        if 'primary_user' in data: computer.primary_user = data['primary_user']
        
        computer.last_checkin = timezone.now()
        computer.save()

        settings_obj = GlobalSettings.load()
        return JsonResponse({
            'status': 'success', 
            'checkin_interval_minutes': settings_obj.agent_checkin_interval_minutes
        }, status=200)

    except json.JSONDecodeError:
        logger.warning(f"Invalid JSON format received at checkin_agent from {request.META.get('REMOTE_ADDR')}")
        return JsonResponse({'error': 'Invalid JSON format'}, status=400)
    except Exception as e:
        logger.error(f"Critical error in checkin_agent: {str(e)}", exc_info=True)
        return JsonResponse({'error': str(e)}, status=500)

# --- WEB DASHBOARD VIEWS ---

@login_required
@require_POST
def update_user_preferences(request):
    """
    Silently handles background AJAX requests to save UI preferences 
    to the user's database profile.
    """
    try:
        data = json.loads(request.body)
        
        profile, created = UserProfile.objects.get_or_create(user=request.user)
        
        if 'rows_per_page' in data:
            profile.rows_per_page = int(data['rows_per_page'])
        
        if 'auto_refresh_interval' in data:
            profile.auto_refresh_interval = int(data['auto_refresh_interval'])
            
        profile.save()
        return JsonResponse({'status': 'success'})
        
    except ValueError:
        return JsonResponse({'status': 'error', 'message': 'Invalid integer provided.'}, status=400)
    except Exception as e:
        return JsonResponse({'status': 'error', 'message': str(e)}, status=400)

def dashboard(request):
    settings_obj = GlobalSettings.load()
    
    if request.user.is_authenticated:
        profile = getattr(request.user, 'profile', None)
        role = profile.role if profile else 'Customer'
        theme = profile.theme if profile else 'auto'

        laps_enabled = settings_obj.jamf_laps_enabled if role in ['Server Administrator', 'Desktop Administrator'] else False

        if role in ['Server Administrator', 'Desktop Administrator']:
            computers = Computer.objects.all().order_by('-last_checkin')
        else:
            computers = Computer.objects.filter(assigned_users=request.user).order_by('-last_checkin')
            
        active_connections = ""
        try:
            active_connections = subprocess.check_output(['ss', '-tna']).decode('utf-8')
        except Exception as e:
            logger.error(f"Failed to run 'ss -tna' command for port polling: {str(e)}")
            pass

        now = timezone.now()
        
        try:
            interval_minutes = int(settings_obj.agent_checkin_interval_minutes)
        except (ValueError, TypeError):
            interval_minutes = 60
            
        grace_period_seconds = (interval_minutes + 15) * 60
        
        for comp in computers:
            time_since_checkin = now - comp.last_checkin if comp.last_checkin else timedelta(days=999)
            seconds_since = time_since_checkin.total_seconds()
            
            if seconds_since < 0:
                seconds_since = abs(seconds_since)
            
            if seconds_since > 86400:
                comp.status_color = 'red'
                comp.status_text = 'Offline (Unreachable for > 24 hours)'
                
            elif seconds_since > grace_period_seconds:
                comp.status_color = 'yellow'
                comp.status_text = 'Offline / Sleeping (Missed recent check-in)'
                
            else:
                is_listening = False
                is_active = False
                
                # IPv4-Only check for the SSH tunnel socket
                try:
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                        s.settimeout(0.05)
                        s.connect(('127.0.0.1', comp.ssh_port))
                        is_listening = True
                except (socket.timeout, ConnectionRefusedError, OSError):
                    pass
                
                if is_listening:
                    ssh_suffix = f":{comp.ssh_port}"
                    vnc_suffix = f":{comp.vnc_port}"
                    
                    for line in active_connections.splitlines():
                        if line.startswith("ESTAB"):
                            parts = line.split()
                            if len(parts) >= 5:
                                local_addr = parts[3]
                                peer_addr = parts[4]
                                
                                if local_addr.endswith(ssh_suffix) or local_addr.endswith(vnc_suffix):
                                    try:
                                        peer_port_str = peer_addr.rsplit(':', 1)[-1]
                                        peer_port = int(peer_port_str)
                                        if peer_port >= 32768:
                                            is_active = True
                                            break
                                    except (ValueError, IndexError):
                                        pass
                            
                    if is_active:
                        comp.status_color = 'blue'
                        comp.status_text = 'Active Session Established'
                    else:
                        comp.status_color = 'green'
                        comp.status_text = 'Online & Tunnel Ready'
                else:
                    comp.status_color = 'yellow'
                    comp.status_text = 'Tunnel Disconnected (Network Interruption)'

    else:
        computers = []
        role = None
        theme = 'auto'
        laps_enabled = False

    return render(request, 'api/dashboard.html', {
        'computers': computers,
        'user_role': role,
        'user_theme': theme,
        'laps_enabled': laps_enabled
    })

def computer_assignments(request):
    if not request.user.is_authenticated:
        return redirect('oidc_authentication_init')
        
    profile = getattr(request.user, 'profile', None)
    role = profile.role if profile else 'Customer'
    
    if role not in ['Server Administrator', 'Desktop Administrator']:
        return redirect('dashboard')
        
    customer_users = User.objects.filter(profile__role='Customer').order_by('username')
    computers = Computer.objects.all().order_by('hostname')
    
    if request.method == 'POST':
        comp_id = request.POST.get('computer_id')
        selected_user_ids = request.POST.getlist('assigned_users')
        
        if comp_id:
            comp = Computer.objects.filter(id=comp_id).first()
            if comp:
                comp.assigned_users.set(selected_user_ids)
                logger.info(f"User '{request.user.username}' updated assignments for computer '{comp.hostname}'.")
        
        return redirect('computer_assignments')
        
    return render(request, 'api/assignments.html', {
        'computers': computers,
        'customers': customer_users,
        'user_role': role,
        'user_theme': profile.theme if profile else 'auto'
    })

def server_settings(request):
    if not request.user.is_authenticated:
        return redirect('oidc_authentication_init')
        
    profile = getattr(request.user, 'profile', None)
    role = profile.role if profile else 'Customer'
    
    if role not in ['Server Administrator', 'Desktop Administrator', 'Customer']:
        return redirect('dashboard')
        
    settings_obj = GlobalSettings.load()
    success = False
    
    if request.method == 'POST':
        if profile:
            theme = request.POST.get('theme')
            if theme in ['auto', 'light', 'dark']:
                profile.theme = theme
            timezone = request.POST.get('timezone')
            if timezone:
                profile.timezone = timezone
            profile.save()

        if role == 'Server Administrator':
            settings_obj.jamf_url = request.POST.get('jamf_url')
            settings_obj.jamf_client_id = request.POST.get('jamf_client_id')
            
            new_secret = request.POST.get('jamf_client_secret')
            if new_secret:
                settings_obj.jamf_client_secret = new_secret
                
            settings_obj.jamf_laps_enabled = request.POST.get('jamf_laps_enabled') == 'on'
            settings_obj.prestage_laps_type = request.POST.get('prestage_laps_type', 'jamf')
            settings_obj.macoslaps_ea_id = request.POST.get('macoslaps_ea_id', '')
            
            interval = request.POST.get('agent_checkin_interval_minutes')
            if interval and interval.isdigit():
                settings_obj.agent_checkin_interval_minutes = int(interval)
            
            settings_obj.custom_server_port_enabled = request.POST.get('custom_server_port_enabled') == 'on'
            if settings_obj.custom_server_port_enabled:
                port = request.POST.get('custom_server_port')
                if port and port.isdigit():
                    settings_obj.custom_server_port = int(port)
            else:
                settings_obj.custom_server_port = 9922
                
            settings_obj.save()
            logger.info(f"Global server settings updated by {request.user.username}.")
            
        success = True
        
    return render(request, 'api/settings.html', {
        'settings': settings_obj, 
        'user_role': role,
        'profile': profile,
        'user_theme': profile.theme if profile else 'auto',
        'success': success
    })

# --- LAPS INTEGRATION VIEWS ---

def laps_usernames(request, jssid):
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    try:
        settings_obj = GlobalSettings.load()
        api = JamfAPI(settings_obj.jamf_url, settings_obj.jamf_client_id, settings_obj.jamf_client_secret)
        mgmt_id = api.get_management_id(jssid)
        
        accounts = api.get_laps_accounts(mgmt_id)
        jamf_user = None
        prestage_user = None
        
        for acc in accounts:
            if acc.get('userSource') == 'JMF':
                jamf_user = acc.get('username')
            elif acc.get('userSource') == 'MDM':
                if settings_obj.prestage_laps_type == 'jamf':
                    prestage_user = acc.get('username')

        if settings_obj.prestage_laps_type == 'macoslaps':
            if settings_obj.macoslaps_ea_id:
                ea_val = api.get_extension_attribute(jssid, settings_obj.macoslaps_ea_id)
                if ea_val:
                    prestage_user = "paeadmin"

        return JsonResponse({
            'status': 'success',
            'jamf_user': jamf_user,
            'prestage_user': prestage_user
        })
    except Exception as e:
        logger.error(f"Error fetching LAPS usernames for JSSID {jssid}: {str(e)}", exc_info=True)
        return JsonResponse({'status': 'error', 'message': str(e)}, status=500)

def laps_password(request, jssid, account_type):
    if not request.user.is_authenticated or not hasattr(request.user, 'profile'):
        return JsonResponse({'status': 'error', 'message': 'Unauthorized'}, status=403)
        
    if request.user.profile.role not in ['Server Administrator', 'Desktop Administrator']:
        logger.warning(f"User {request.user.username} attempted to view LAPS password without sufficient privileges.")
        return JsonResponse({'status': 'error', 'message': 'Access Denied'}, status=403)
        
    settings_obj = GlobalSettings.load()
    if not settings_obj.jamf_laps_enabled:
        return JsonResponse({'status': 'error', 'message': 'LAPS is currently disabled globally.'}, status=400)
        
    try:
        api = JamfAPI(settings_obj.jamf_url, settings_obj.jamf_client_id, settings_obj.jamf_client_secret)
        logger.info(f"User {request.user.username} requested LAPS password for JSSID {jssid} (Account Type: {account_type})")
        
        if account_type == 'jamf':
            mgmt_id = api.get_management_id(jssid)
            accounts = api.get_laps_accounts(mgmt_id)
            username = next((acc.get('username') for acc in accounts if acc.get('userSource') == 'JMF'), None)
            if not username:
                return JsonResponse({'status': 'error', 'message': 'Jamf Admin LAPS account not found.'}, status=404)
            password = api.get_laps_password(mgmt_id, username)
            return JsonResponse({'status': 'success', 'password': password})
            
        elif account_type == 'prestage':
            if settings_obj.prestage_laps_type == 'macoslaps':
                if not settings_obj.macoslaps_ea_id:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS EA ID is not configured.'}, status=400)
                password = api.get_extension_attribute(jssid, settings_obj.macoslaps_ea_id)
                if not password:
                    return JsonResponse({'status': 'error', 'message': 'macOSLAPS password was empty or not found.'}, status=404)
                return JsonResponse({'status': 'success', 'password': password})
            else:
                mgmt_id = api.get_management_id(jssid)
                accounts = api.get_laps_accounts(mgmt_id)
                username = next((acc.get('username') for acc in accounts if acc.get('userSource') == 'MDM'), None)
                if not username:
                    return JsonResponse({'status': 'error', 'message': 'PreStage Admin LAPS account not found.'}, status=404)
                password = api.get_laps_password(mgmt_id, username)
                return JsonResponse({'status': 'success', 'password': password})
        else:
            return JsonResponse({'status': 'error', 'message': 'Invalid account type specified.'}, status=400)
            
    except Exception as e:
        logger.error(f"Error fetching LAPS password for JSSID {jssid}: {str(e)}", exc_info=True)
        return JsonResponse({'status': 'error', 'message': f"Jamf API Error: {str(e)}"}, status=500)