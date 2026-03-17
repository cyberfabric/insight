# ADR-001: Backend Framework Selection - Django

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/backend/PRD.md`

## Context

The Git Stats Backend requires a web framework to build a REST API server with:
- Authentication and authorization (SSO/OIDC + local credentials)
- User management with role-based access control (RBAC)
- Data proxy for analytics database queries
- Session management and security features
- API token authentication
- Admin interface for system management
- Performance monitoring and logging
- Support for 100+ concurrent users with sub-500ms response times

The application needs to:
- Integrate with enterprise SSO (ZTA Passport/OIDC)
- Proxy queries to analytics database with permission enforcement
- Manage user profiles, roles, and granular permissions
- Provide structured REST endpoints for frontend consumption
- Support horizontal scalability

## Decision

We will use **Django 4.2+** (LTS) with **Django REST Framework 3.14+** as the backend framework for the Git Stats Backend API.

## Rationale

### Why Django

1. **Batteries Included**: Django provides built-in features out of the box:
   - ORM for database abstraction
   - Authentication and session management
   - Admin interface for data management
   - Security features (CSRF, XSS, SQL injection protection)
   - Middleware system for request/response processing

2. **Django REST Framework (DRF)**: Industry-standard toolkit for building REST APIs:
   - Serializers for data validation and transformation
   - ViewSets and routers for rapid API development
   - Authentication classes (session, token, OAuth)
   - Permission classes for fine-grained access control
   - Pagination, filtering, and search built-in

3. **Security First**: Django's security features align with enterprise requirements:
   - Built-in protection against common vulnerabilities (OWASP Top 10)
   - Secure password hashing (PBKDF2, Argon2, bcrypt)
   - HTTPS enforcement and secure cookie handling
   - CORS middleware for frontend integration
   - Regular security updates from Django Security Team

4. **Authentication Flexibility**: Supports multiple authentication methods:
   - Session-based authentication for web clients
   - Token authentication for API clients
   - OAuth2/OIDC integration via third-party packages (django-allauth, mozilla-django-oidc)
   - Custom authentication backends for enterprise SSO

5. **ORM Abstraction**: Django ORM simplifies database operations:
   - Database-agnostic queries (SQLite, PostgreSQL, MySQL)
   - Migration system for schema changes
   - Query optimization and caching
   - Transaction management

6. **Admin Interface**: Django admin provides free system management UI:
   - User and permission management
   - Data browsing and editing
   - Customizable for specific needs
   - Reduces development time for admin features

7. **Mature Ecosystem**: 
   - 75k+ GitHub stars
   - 18+ years of development
   - Extensive third-party packages (django-cors-headers, django-filter, etc.)
   - Large community and documentation

8. **Performance**: 
   - Handles 100+ concurrent users efficiently
   - Middleware caching and query optimization
   - Async views support (Django 4.2+)
   - Horizontal scalability with stateless design

9. **Team Expertise**: Development team has Django experience, reducing onboarding time.

### Alternatives Considered

#### Flask
- **Pros**: Lightweight, flexible, minimal boilerplate, easier learning curve
- **Cons**: No built-in admin, ORM, or authentication; requires manual security configuration; more code for same features
- **Verdict**: Rejected due to lack of built-in features and increased development time

#### FastAPI
- **Pros**: Modern async framework, automatic OpenAPI docs, excellent performance, type hints
- **Cons**: Newer ecosystem, no built-in admin, less mature authentication libraries, team learning curve
- **Verdict**: Rejected due to ecosystem maturity and team expertise gap

#### Express.js (Node.js)
- **Pros**: JavaScript full-stack, large ecosystem, async by default
- **Cons**: No built-in ORM or admin, weaker type system, different language from data science tools
- **Verdict**: Rejected due to lack of built-in features and language mismatch

#### Spring Boot (Java)
- **Pros**: Enterprise-grade, excellent performance, strong typing, mature ecosystem
- **Cons**: Verbose configuration, heavier resource usage, steeper learning curve, slower development
- **Verdict**: Rejected due to development velocity and resource overhead

#### Ruby on Rails
- **Pros**: Convention over configuration, rapid development, mature ecosystem
- **Cons**: Slower performance than Python, smaller community than Django, declining popularity
- **Verdict**: Rejected due to performance concerns and declining ecosystem

#### ASP.NET Core (C#)
- **Pros**: Excellent performance, strong typing, mature ecosystem, Microsoft support
- **Cons**: Windows-centric (though cross-platform now), team learning curve, different language
- **Verdict**: Rejected due to team expertise and platform preferences

## Consequences

### Positive

- **Rapid Development**: Built-in features accelerate API development by 40-50%
- **Security**: Django's security features reduce vulnerability risk
- **Admin Interface**: Free admin UI saves 2-3 weeks of development time
- **Authentication**: Multiple auth methods support SSO and local credentials
- **Maintainability**: Django conventions improve code consistency and readability
- **Scalability**: Stateless design enables horizontal scaling to 100+ concurrent users
- **Ecosystem**: Large package ecosystem provides solutions for common problems

### Negative

- **Monolithic**: Django's "batteries included" approach adds unused features to bundle
- **ORM Limitations**: Complex queries may require raw SQL for analytics database
- **Learning Curve**: New team members need Django knowledge (mitigated by team expertise)
- **Performance**: Slightly slower than async frameworks like FastAPI (acceptable for requirements)

### Neutral

- **Python Version**: Requires Python 3.11+ for latest features and performance
- **Database**: Django ORM works best with relational databases (SQLite for user data)
- **Async Support**: Django 4.2+ supports async views, but ecosystem still catching up

## Implementation Notes

### Project Structure

```
git-stats-backend/
├── config/
│   ├── settings.py          # Django settings
│   ├── urls.py              # URL routing
│   └── wsgi.py              # WSGI application
├── apps/
│   ├── authentication/      # SSO and local auth
│   ├── users/               # User management
│   ├── permissions/         # RBAC and permissions
│   ├── data_proxy/          # Analytics database proxy
│   └── monitoring/          # Performance monitoring
├── manage.py
└── requirements.txt
```

### Key Dependencies

```python
# requirements.txt
Django==4.2.11                    # Web framework (LTS)
djangorestframework==3.14.0       # REST API toolkit
django-cors-headers==4.3.1        # CORS support
mozilla-django-oidc==4.0.1        # OIDC authentication
django-filter==23.5               # Query filtering
python-decouple==3.8              # Environment variables
gunicorn==21.2.0                  # WSGI server
```

### Settings Configuration

```python
# config/settings.py

# Security
SECRET_KEY = config('SECRET_KEY')
DEBUG = config('DEBUG', default=False, cast=bool)
ALLOWED_HOSTS = config('ALLOWED_HOSTS', cast=lambda v: [s.strip() for s in v.split(',')])

# CORS
CORS_ALLOWED_ORIGINS = [
    "http://localhost:3000",  # Development frontend
    "https://gitstats.example.com",  # Production frontend
]
CORS_ALLOW_CREDENTIALS = True

# Authentication
AUTHENTICATION_BACKENDS = [
    'mozilla_django_oidc.auth.OIDCAuthenticationBackend',
    'django.contrib.auth.backends.ModelBackend',  # Local auth fallback
]

# Session
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'

# REST Framework
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.SessionAuthentication',
        'rest_framework.authentication.TokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 100,
}
```

### API Endpoint Pattern

```python
# apps/data_proxy/views.py
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from .permissions import HasPagePermission

class CommitsView(APIView):
    permission_classes = [IsAuthenticated, HasPagePermission]
    
    def get(self, request):
        # Validate permissions
        if not request.user.has_perm('view_commits_page'):
            return Response({'error': 'Permission denied'}, status=403)
        
        # Validate query parameters
        filters = self.validate_filters(request.query_params)
        
        # Execute analytics database query
        results = self.query_analytics_db(filters)
        
        # Log for performance monitoring
        self.log_query(request.user, 'commits', filters)
        
        return Response(results)
```

### OIDC Integration

```python
# config/settings.py
OIDC_RP_CLIENT_ID = config('OIDC_CLIENT_ID')
OIDC_RP_CLIENT_SECRET = config('OIDC_CLIENT_SECRET')
OIDC_OP_AUTHORIZATION_ENDPOINT = config('OIDC_AUTH_ENDPOINT')
OIDC_OP_TOKEN_ENDPOINT = config('OIDC_TOKEN_ENDPOINT')
OIDC_OP_USER_ENDPOINT = config('OIDC_USER_ENDPOINT')
```

## Compliance

- **Performance**: Django handles 100+ concurrent users with sub-500ms response times
- **Security**: Built-in security features meet enterprise requirements
- **Scalability**: Stateless design enables horizontal scaling
- **Authentication**: Supports SSO (OIDC) and local credentials
- **Admin**: Django admin provides system management interface

## References

- [Django Documentation](https://docs.djangoproject.com/)
- [Django REST Framework](https://www.django-rest-framework.org/)
- [Django Security](https://docs.djangoproject.com/en/4.2/topics/security/)
- [mozilla-django-oidc](https://mozilla-django-oidc.readthedocs.io/)
- Backend PRD: `docs/backend/PRD.md`
