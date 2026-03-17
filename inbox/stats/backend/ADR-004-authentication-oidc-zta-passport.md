# ADR-004: Authentication System Selection - OIDC with ZTA Passport

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/backend/PRD.md`  
**Related ADR**: `ADR-001-backend-framework-django.md`

## Context

The Git Stats Backend requires an authentication system that:
- Integrates with enterprise SSO (Single Sign-On)
- Supports local username/password for development
- Provides secure session management
- Enables API token authentication for programmatic access
- Meets enterprise security requirements
- Supports 100+ concurrent users
- Provides 99.9% authentication uptime

Requirements:
- Enterprise SSO integration (production)
- Local authentication fallback (development)
- Session-based authentication for web clients
- Token-based authentication for API clients
- Secure cookie handling (HttpOnly, Secure, SameSite)
- CSRF protection
- Password hashing with industry-standard algorithms

Enterprise constraints:
- Must integrate with ZTA Passport (enterprise OIDC provider)
- Must support Zero Trust Architecture principles
- Must validate users against Panopticum (enterprise directory)
- Must support role-based access control (RBAC)

## Decision

We will use **OpenID Connect (OIDC)** with **ZTA Passport** as the primary authentication provider, with **Django's built-in authentication** as a fallback for local development.

## Rationale

### Why OIDC with ZTA Passport

1. **Enterprise Standard**: OIDC is the modern authentication standard:
   - Built on OAuth 2.0
   - Industry-standard protocol (Google, Microsoft, Okta)
   - Better than SAML (simpler, JSON-based, mobile-friendly)
   - Widely supported by libraries and frameworks

2. **Zero Trust Architecture**: ZTA Passport provides enterprise-grade security:
   - No implicit trust based on network location
   - Continuous authentication and authorization
   - Centralized identity management
   - Audit logging and compliance

3. **Single Sign-On**: Users authenticate once across all enterprise apps:
   - Improved user experience (no multiple passwords)
   - Centralized password policy enforcement
   - Reduced password fatigue and reuse
   - Simplified onboarding/offboarding

4. **Security Benefits**:
   - No password storage in application database
   - Centralized credential management
   - Multi-factor authentication (MFA) support
   - Session timeout and refresh token rotation
   - Centralized audit logging

5. **Django Integration**: `mozilla-django-oidc` provides seamless integration:
   - Automatic user creation on first login
   - Session management handled by Django
   - Custom authentication backend support
   - Active maintenance and security updates

6. **Development Flexibility**: Local auth fallback enables development:
   - No dependency on enterprise SSO for local development
   - Faster development iteration
   - Test user creation without SSO access
   - Offline development support

### OIDC Flow

```
1. User clicks "Login with SSO"
2. Backend redirects to ZTA Passport authorization endpoint
3. User authenticates with ZTA Passport (username/password + MFA)
4. ZTA Passport redirects back with authorization code
5. Backend exchanges code for ID token and access token
6. Backend validates ID token signature and claims
7. Backend creates/updates user in local database
8. Backend creates Django session
9. User is authenticated and redirected to dashboard
```

### Alternatives Considered

#### SAML 2.0
- **Pros**: Enterprise standard, mature protocol, wide adoption
- **Cons**: XML-based (complex), poor mobile support, harder to implement, legacy protocol
- **Verdict**: Rejected in favor of modern OIDC standard

#### OAuth 2.0 (without OIDC)
- **Pros**: Simple, widely adopted, flexible
- **Cons**: Authorization only (not authentication), no standardized user info, requires custom implementation
- **Verdict**: Rejected because OIDC extends OAuth 2.0 with authentication

#### LDAP/Active Directory
- **Pros**: Direct directory integration, simple protocol
- **Cons**: Requires storing passwords, no SSO, poor security, legacy protocol
- **Verdict**: Rejected due to security concerns and lack of SSO

#### JWT-based Custom Auth
- **Pros**: Stateless, flexible, modern
- **Cons**: No enterprise SSO, requires custom implementation, security risks if implemented incorrectly
- **Verdict**: Rejected due to lack of enterprise SSO integration

#### Basic Authentication
- **Pros**: Simple, built into HTTP
- **Cons**: No SSO, credentials in every request, poor security, no session management
- **Verdict**: Rejected due to security concerns

## Consequences

### Positive

- **Enterprise Integration**: Seamless SSO with ZTA Passport
- **Security**: No password storage, centralized credential management
- **User Experience**: Single sign-on across enterprise applications
- **Compliance**: Centralized audit logging and MFA support
- **Development**: Local auth fallback enables offline development
- **Maintenance**: Centralized password policy and user management

### Negative

- **Dependency**: Requires ZTA Passport availability (99.9% uptime SLA)
- **Complexity**: OIDC flow more complex than basic auth
- **Network**: Requires network connectivity to ZTA Passport
- **Testing**: Integration tests require mock OIDC provider

### Neutral

- **Session Management**: Django sessions stored in database (acceptable for 100+ users)
- **Token Refresh**: Refresh tokens require periodic renewal (handled by library)
- **User Sync**: User data synced from ZTA Passport on each login

## Implementation Notes

### Django Settings

```python
# config/settings.py

# Authentication backends
AUTHENTICATION_BACKENDS = [
    'mozilla_django_oidc.auth.OIDCAuthenticationBackend',  # SSO (production)
    'django.contrib.auth.backends.ModelBackend',           # Local (development)
]

# OIDC Configuration
OIDC_RP_CLIENT_ID = config('OIDC_CLIENT_ID')
OIDC_RP_CLIENT_SECRET = config('OIDC_CLIENT_SECRET')
OIDC_OP_AUTHORIZATION_ENDPOINT = config('OIDC_AUTH_ENDPOINT')
OIDC_OP_TOKEN_ENDPOINT = config('OIDC_TOKEN_ENDPOINT')
OIDC_OP_USER_ENDPOINT = config('OIDC_USER_ENDPOINT')
OIDC_OP_JWKS_ENDPOINT = config('OIDC_JWKS_ENDPOINT')

# OIDC Settings
OIDC_RP_SIGN_ALGO = 'RS256'
OIDC_RP_SCOPES = 'openid email profile'
OIDC_RENEW_ID_TOKEN_EXPIRY_SECONDS = 3600  # 1 hour

# Session Configuration
SESSION_COOKIE_SECURE = True  # HTTPS only
SESSION_COOKIE_HTTPONLY = True  # No JavaScript access
SESSION_COOKIE_SAMESITE = 'Lax'  # CSRF protection
SESSION_COOKIE_AGE = 86400  # 24 hours

# CSRF Protection
CSRF_COOKIE_SECURE = True
CSRF_COOKIE_HTTPONLY = True
CSRF_COOKIE_SAMESITE = 'Lax'
```

### Custom OIDC Backend

```python
# apps/authentication/oidc_backend.py
from mozilla_django_oidc.auth import OIDCAuthenticationBackend
from apps.users.models import User

class CustomOIDCBackend(OIDCAuthenticationBackend):
    def create_user(self, claims):
        """Create user from OIDC claims"""
        email = claims.get('email')
        username = claims.get('preferred_username', email)
        
        user = User.objects.create_user(
            username=username,
            email=email,
            panopticum_id=claims.get('panopticum_id'),
        )
        
        return user
    
    def update_user(self, user, claims):
        """Update user from OIDC claims on each login"""
        user.email = claims.get('email')
        user.panopticum_id = claims.get('panopticum_id')
        user.save()
        
        return user
    
    def filter_users_by_claims(self, claims):
        """Find user by email"""
        email = claims.get('email')
        if not email:
            return self.UserModel.objects.none()
        
        return self.UserModel.objects.filter(email=email)
```

### URL Configuration

```python
# config/urls.py
from django.urls import path, include

urlpatterns = [
    # OIDC endpoints
    path('oidc/', include('mozilla_django_oidc.urls')),
    
    # Custom auth endpoints
    path('api/auth/login/', views.login_view),
    path('api/auth/logout/', views.logout_view),
    path('api/auth/me/', views.current_user_view),
]
```

### Login View

```python
# apps/authentication/views.py
from django.contrib.auth import authenticate, login
from rest_framework.decorators import api_view
from rest_framework.response import Response

@api_view(['POST'])
def login_view(request):
    """Local authentication for development"""
    username = request.data.get('username')
    password = request.data.get('password')
    
    user = authenticate(request, username=username, password=password)
    
    if user is not None:
        login(request, user)
        return Response({
            'user': {
                'id': user.id,
                'username': user.username,
                'email': user.email,
                'role': user.role,
            }
        })
    else:
        return Response({'error': 'Invalid credentials'}, status=401)

@api_view(['GET'])
def current_user_view(request):
    """Get current authenticated user"""
    if not request.user.is_authenticated:
        return Response({'error': 'Not authenticated'}, status=401)
    
    return Response({
        'user': {
            'id': request.user.id,
            'username': request.user.username,
            'email': request.user.email,
            'role': request.user.role,
            'permissions': {
                'pages': list(request.user.page_permissions.values_list('page_name', flat=True)),
                'charts': list(request.user.chart_permissions.values_list('chart_name', flat=True)),
            }
        }
    })
```

### API Token Authentication

```python
# apps/authentication/models.py
from django.db import models
from django.contrib.auth import get_user_model
import secrets

User = get_user_model()

class APIToken(models.Model):
    """API tokens for programmatic access"""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='api_tokens')
    token = models.CharField(max_length=64, unique=True)
    name = models.CharField(max_length=100)
    created_at = models.DateTimeField(auto_now_add=True)
    last_used_at = models.DateTimeField(null=True)
    is_active = models.BooleanField(default=True)
    
    @classmethod
    def generate_token(cls, user, name):
        """Generate new API token"""
        token = secrets.token_urlsafe(48)
        return cls.objects.create(user=user, token=token, name=name)
    
    class Meta:
        db_table = 'api_tokens'

# Custom authentication class
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed

class APITokenAuthentication(BaseAuthentication):
    def authenticate(self, request):
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        
        if not token:
            return None
        
        try:
            api_token = APIToken.objects.select_related('user').get(
                token=token,
                is_active=True
            )
            api_token.last_used_at = timezone.now()
            api_token.save(update_fields=['last_used_at'])
            
            return (api_token.user, api_token)
        except APIToken.DoesNotExist:
            raise AuthenticationFailed('Invalid token')
```

### Testing with Mock OIDC

```python
# tests/test_authentication.py
from unittest.mock import patch
from django.test import TestCase

class OIDCAuthenticationTest(TestCase):
    @patch('mozilla_django_oidc.auth.OIDCAuthenticationBackend.verify_token')
    @patch('mozilla_django_oidc.auth.OIDCAuthenticationBackend.get_userinfo')
    def test_oidc_login(self, mock_userinfo, mock_verify):
        """Test OIDC authentication flow"""
        mock_verify.return_value = True
        mock_userinfo.return_value = {
            'email': 'test@example.com',
            'preferred_username': 'testuser',
            'panopticum_id': '12345',
        }
        
        # Test authentication
        response = self.client.get('/oidc/callback/?code=test_code')
        self.assertEqual(response.status_code, 302)
        
        # Verify user created
        user = User.objects.get(email='test@example.com')
        self.assertEqual(user.username, 'testuser')
```

## Compliance

- **Security**: OIDC provides enterprise-grade authentication security
- **SSO**: Seamless integration with ZTA Passport
- **Uptime**: 99.9% authentication uptime (dependent on ZTA Passport SLA)
- **Development**: Local auth fallback enables offline development
- **API Access**: Token authentication supports programmatic access

## References

- [OpenID Connect Specification](https://openid.net/connect/)
- [mozilla-django-oidc Documentation](https://mozilla-django-oidc.readthedocs.io/)
- [Django Authentication](https://docs.djangoproject.com/en/4.2/topics/auth/)
- [OAuth 2.0 and OIDC Best Practices](https://oauth.net/2/)
- Backend PRD: `docs/backend/PRD.md`
- Related ADR: `ADR-001-backend-framework-django.md`
