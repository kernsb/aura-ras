import requests
import logging

logger = logging.getLogger(__name__)

class JamfAPI:
    def __init__(self, url, client_id, client_secret):
        self.base_url = url.rstrip('/') if url else ''
        self.client_id = client_id
        self.client_secret = client_secret

    def _get_token(self):
        """Requests an OAuth Bearer token using API Client Credentials"""
        if not self.base_url or not self.client_id or not self.client_secret:
            raise ValueError("Jamf Integration is not fully configured in Global Settings.")
            
        auth_url = f"{self.base_url}/api/oauth/token"
        payload = {
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "grant_type": "client_credentials"
        }
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        
        response = requests.post(auth_url, data=payload, headers=headers)
        response.raise_for_status()
        return response.json().get('access_token')

    def get_management_id(self, jssid):
        """Fetches the unique Jamf Pro API Management ID for a specific computer"""
        token = self._get_token()
        url = f"{self.base_url}/api/v1/computers-inventory-detail/{jssid}"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        data = response.json()
        return data.get('general', {}).get('managementId')

    def get_laps_accounts(self, management_id):
        """Fetches all configured LAPS accounts from Jamf Pro"""
        if not management_id:
            return []
        token = self._get_token()
        url = f"{self.base_url}/api/v2/local-admin-password/{management_id}/accounts"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        try:
            response = requests.get(url, headers=headers)
            if response.status_code == 200:
                return response.json().get('results', [])
            return []
        except requests.exceptions.RequestException:
            return []

    def get_laps_password(self, management_id, guid):
        """Triggers a viewing event and fetches the LAPS password for a specific account guid"""
        token = self._get_token()
        url = f"{self.base_url}/api/v2/local-admin-password/{management_id}/account/{guid}/password"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        return response.json().get('password')

    def get_extension_attribute(self, jssid, ea_id):
        """Fetches the macOSLAPS password stored in an Extension Attribute using Classic API"""
        token = self._get_token()
        url = f"{self.base_url}/JSSResource/computers/id/{jssid}"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        try:
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            
            eas = response.json().get('computer', {}).get('extension_attributes', [])
            for ea in eas:
                if str(ea.get('id')) == str(ea_id):
                    return ea.get('value')
        except requests.exceptions.RequestException:
            return None
        return None
