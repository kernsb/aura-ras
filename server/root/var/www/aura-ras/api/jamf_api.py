import requests
import logging

logger = logging.getLogger(__name__)

class JamfAPI:
    def __init__(self, base_url, client_id, client_secret):
        self.base_url = base_url.rstrip('/')
        self.client_id = client_id
        self.client_secret = client_secret

    def _get_token(self):
        """Fetches the Bearer token from Jamf Pro."""
        url = f"{self.base_url}/api/oauth/token"
        response = requests.post(
            url, 
            data={"client_id": self.client_id, "client_secret": self.client_secret, "grant_type": "client_credentials"}
        )
        response.raise_for_status()
        return response.json().get('access_token')

    def get_management_id(self, jssid):
        """Fetches the client management ID (UUID) for a given JSSID using Jamf Pro API v3"""
        token = self._get_token()
        url = f"{self.base_url}/api/v3/computers-inventory-detail/{jssid}"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        response = requests.get(url, headers=headers)
        if response.status_code == 200:
            return response.json().get('general', {}).get('managementId')
        
        response.raise_for_status()
        return None

    def get_laps_accounts(self, management_id):
        """Fetches all configured LAPS accounts from Jamf Pro (V2 API)"""
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
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching LAPS accounts: {e}")
            return []

    def get_laps_password(self, management_id, username):
        """Triggers a viewing event and fetches the LAPS password for a specific account username (V2 API)"""
        token = self._get_token()
        url = f"{self.base_url}/api/v2/local-admin-password/{management_id}/account/{username}/password"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        response = requests.get(url, headers=headers)
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return response.json().get('password')

    def get_extension_attribute(self, jssid, ea_id):
        """Fetches an Extension Attribute value for macOSLAPS using Jamf Pro API v3"""
        token = self._get_token()
        url = f"{self.base_url}/api/v3/computers-inventory-detail/{jssid}"
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        
        try:
            response = requests.get(url, headers=headers)
            if response.status_code == 200:
                data = response.json()
                
                # In the V3 API, Extension Attributes are nested inside their respective 
                # logical categories (e.g., 'general', 'userAndLocation', 'hardware').
                # We iterate through all top-level categories to find the matching EA.
                for category_key, category_data in data.items():
                    if isinstance(category_data, dict) and 'extensionAttributes' in category_data:
                        for ea in category_data['extensionAttributes']:
                            # Jamf sometimes uses 'definitionId' or 'id' depending on the exact schema version
                            current_id = str(ea.get('definitionId', ea.get('id', '')))
                            if current_id == str(ea_id):
                                # V3 returns EA values as an array of strings
                                values = ea.get('values', [])
                                if values:
                                    return values[0]
            return None
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching EA: {e}")
            return None