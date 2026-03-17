# ADR-002: User Database Selection - PostgreSQL (Production) / SQLite (Development)

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/backend/PRD.md`  
**Related ADR**: `ADR-001-backend-framework-django.md`

## Context

The Git Stats Backend requires a database to store:
- User profiles (username, email, role)
- Authentication sessions
- User permissions (page and chart visibility)
- User settings and preferences
- Author alias mappings
- API tokens for programmatic access

Requirements:
- Support 100+ concurrent users
- Sub-500ms query response times
- Simple deployment (no separate database server)
- ACID transactions for data integrity
- Django ORM compatibility
- Backup and recovery capabilities
- Low operational overhead

Data characteristics:
- Small dataset (~500 users, ~5,000 permission records)
- Read-heavy workload (90% reads, 10% writes)
- Simple relational schema
- No complex joins or aggregations
- Infrequent schema changes

## Decision

We will use **PostgreSQL 14+** as the production user database for storing authentication, user profiles, permissions, and settings.

**SQLite 3.35+** is used as a **temporary development-only solution** and must be replaced with PostgreSQL before production deployment.

## Rationale

### Why PostgreSQL for Production

1. **Production-Grade Concurrency**: PostgreSQL handles 100+ concurrent users with MVCC (Multi-Version Concurrency Control):
   - Multiple simultaneous writes without blocking
   - Read operations never block writes
   - True concurrent transaction support
   - Connection pooling support

2. **Reliability & ACID Compliance**: Enterprise-grade reliability:
   - Full ACID transaction support
   - Write-ahead logging (WAL) for crash recovery
   - Point-in-time recovery (PITR)
   - Replication for high availability

3. **Scalability**: Designed for production workloads:
   - Handles millions of rows efficiently
   - Horizontal scaling with read replicas
   - Connection pooling (pgBouncer, PgPool)
   - Partitioning for large tables

4. **Advanced Features**:
   - JSON/JSONB support for flexible schemas
   - Full-text search capabilities
   - Rich indexing options (B-tree, GiST, GIN, BRIN)
   - Stored procedures and triggers

5. **Django Integration**: First-class Django support:
   - Full ORM compatibility
   - Migration system works seamlessly
   - Django admin fully supported
   - Extensive documentation

6. **Operational Maturity**:
   - Battle-tested in production (30+ years)
   - Excellent monitoring tools (pg_stat_statements, pgAdmin)
   - Automated backup solutions
   - Active community and support

7. **Security**: Enterprise security features:
   - Row-level security (RLS)
   - SSL/TLS encryption
   - Fine-grained access control
   - Audit logging

### Why SQLite for Development Only

1. **Zero Configuration**: No separate database server required:
   - Single file database (`db.sqlite3`)
   - No installation or setup needed
   - No connection pooling configuration
   - No network overhead

2. **Simplicity**: Ideal for small-to-medium datasets:
   - Handles 500+ users efficiently
   - Sub-millisecond query times for simple queries
   - Perfect for read-heavy workloads
   - ACID compliant for data integrity

3. **Django Integration**: First-class Django support:
   - Default database for Django projects
   - Full ORM compatibility
   - Migration system works seamlessly
   - Django admin works out of the box

4. **Deployment Simplicity**: 
   - No separate database server to manage
   - Single file backup (copy `db.sqlite3`)
   - No database credentials to manage
   - Containerization is straightforward

5. **Performance**: Sufficient for requirements:
   - Handles 100+ concurrent users (read-heavy workload)
   - Sub-millisecond query times for user lookups
   - Write-ahead logging (WAL) mode for concurrent reads
   - In-process database (no network latency)

6. **Reliability**: 
   - Battle-tested (20+ years)
   - Used by billions of devices
   - ACID transactions ensure data integrity
   - Corruption-resistant with proper configuration

7. **Cost**: Zero licensing or hosting costs

8. **Development Experience**: 
   - Instant local development setup
   - No Docker containers needed for database
   - Easy to reset and seed data
   - Fast test execution

### Why NOT SQLite for Production

1. **Concurrency Limitations**: 
   - Write operations lock entire database
   - Not suitable for 100+ concurrent users
   - Write contention causes performance degradation

2. **Scalability Ceiling**:
   - Single-file database limits horizontal scaling
   - No replication support
   - Cannot distribute across multiple servers

3. **Production Operations**:
   - No network access (file-based only)
   - Limited backup options (requires application downtime)
   - No built-in monitoring or profiling tools
   - No connection pooling

4. **Risk**: Using SQLite in production with 100+ concurrent users will cause:
   - Database lock errors
   - Slow write operations
   - Poor user experience
   - Data corruption risk under high load

### Alternatives Considered

#### MySQL/MariaDB
- **Pros**: Mature, scalable, good performance, wide adoption
- **Cons**: Less advanced features than PostgreSQL, weaker JSON support, more complex replication
- **Verdict**: Rejected in favor of PostgreSQL's superior feature set

#### MongoDB
- **Pros**: Flexible schema, JSON documents, horizontal scaling
- **Cons**: Overkill for relational data, no Django ORM support, requires separate server
- **Verdict**: Rejected due to poor fit for relational data and operational overhead

#### Redis
- **Pros**: Extremely fast, in-memory, simple key-value store
- **Cons**: No relational model, no ACID transactions, data persistence concerns, not suitable for primary database
- **Verdict**: Rejected as not suitable for primary user data storage

#### In-Memory (Django ORM with dict)
- **Pros**: Fastest possible, no I/O overhead
- **Cons**: Data loss on restart, no persistence, no ACID, not production-ready
- **Verdict**: Rejected due to lack of persistence

## Consequences

### Positive (PostgreSQL Production)

- **Production Ready**: Handles 100+ concurrent users without performance degradation
- **Reliability**: Enterprise-grade ACID compliance and crash recovery
- **Scalability**: Horizontal scaling with read replicas for future growth
- **Monitoring**: Rich tooling for performance analysis and optimization
- **Backup**: Point-in-time recovery and automated backup solutions
- **Security**: Row-level security and audit logging for compliance

### Positive (SQLite Development)

- **Zero Setup**: Instant local development without Docker or database server
- **Fast Iteration**: Quick database resets and test execution
- **Portability**: Single file makes sharing development databases easy
- **Cost**: No development database hosting costs

### Negative

- **Migration Required**: Must migrate from SQLite to PostgreSQL before production
- **Environment Parity**: Development (SQLite) differs from production (PostgreSQL)
- **Setup Complexity**: PostgreSQL requires database server installation and configuration
- **Operational Overhead**: PostgreSQL requires monitoring, backups, and maintenance

### Neutral

- **Django Compatibility**: Both databases fully supported by Django ORM
- **Migration Path**: Django migrations work seamlessly across both databases
- **Connection Pooling**: PostgreSQL requires pgBouncer or PgPool for optimal performance

## Implementation Notes

### Django Settings

```python
# config/settings.py
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
        'OPTIONS': {
            'timeout': 20,  # Increase timeout for concurrent writes
            'check_same_thread': False,  # Allow multi-threaded access
        }
    }
}
```

### Enable WAL Mode

```python
# config/settings.py
# Enable Write-Ahead Logging for better concurrent reads
from django.db.backends.signals import connection_created
from django.dispatch import receiver

@receiver(connection_created)
def enable_wal_mode(sender, connection, **kwargs):
    if connection.vendor == 'sqlite':
        cursor = connection.cursor()
        cursor.execute('PRAGMA journal_mode=WAL;')
        cursor.execute('PRAGMA synchronous=NORMAL;')
        cursor.execute('PRAGMA cache_size=-64000;')  # 64MB cache
        cursor.execute('PRAGMA temp_store=MEMORY;')
```

### Database Schema

```python
# apps/users/models.py
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    """Extended user model with additional fields"""
    panopticum_id = models.CharField(max_length=100, unique=True, null=True)
    role = models.CharField(
        max_length=20,
        choices=[('admin', 'Admin'), ('user', 'User')],
        default='user'
    )
    is_active = models.BooleanField(default=True)
    settings = models.JSONField(default=dict)
    
    class Meta:
        db_table = 'users'
        indexes = [
            models.Index(fields=['email']),
            models.Index(fields=['panopticum_id']),
        ]

class Permission(models.Model):
    """User permissions for pages and charts"""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='permissions')
    resource_type = models.CharField(max_length=20)  # 'page' or 'chart'
    resource_name = models.CharField(max_length=100)
    is_allowed = models.BooleanField(default=True)
    
    class Meta:
        db_table = 'permissions'
        unique_together = [['user', 'resource_type', 'resource_name']]
        indexes = [
            models.Index(fields=['user', 'resource_type']),
        ]
```

### Backup Strategy

```bash
#!/bin/bash
# backup.sh - Simple SQLite backup script

# Create backup directory
mkdir -p backups

# Backup with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
sqlite3 db.sqlite3 ".backup backups/db_backup_${TIMESTAMP}.sqlite3"

# Keep only last 7 days of backups
find backups/ -name "db_backup_*.sqlite3" -mtime +7 -delete

echo "Backup completed: backups/db_backup_${TIMESTAMP}.sqlite3"
```

### Performance Optimization

```python
# Query optimization examples

# Use select_related for foreign keys (reduces queries)
users = User.objects.select_related('profile').all()

# Use prefetch_related for many-to-many (reduces queries)
users = User.objects.prefetch_related('permissions').all()

# Index frequently queried fields
class User(AbstractUser):
    class Meta:
        indexes = [
            models.Index(fields=['email']),
            models.Index(fields=['is_active', 'role']),
        ]
```

### PostgreSQL Production Configuration

```python
# config/settings.py
import os

# Use environment variable to switch between SQLite (dev) and PostgreSQL (prod)
if os.environ.get('ENVIRONMENT') == 'production':
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': os.environ.get('DB_NAME', 'gitstats'),
            'USER': os.environ.get('DB_USER', 'postgres'),
            'PASSWORD': os.environ.get('DB_PASSWORD'),
            'HOST': os.environ.get('DB_HOST', 'localhost'),
            'PORT': os.environ.get('DB_PORT', '5432'),
            'CONN_MAX_AGE': 600,  # Connection pooling
            'OPTIONS': {
                'sslmode': 'require',  # Enforce SSL
            },
        }
    }
else:
    # Development: SQLite
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.sqlite3',
            'NAME': BASE_DIR / 'db.sqlite3',
        }
    }
```

### Migration from SQLite to PostgreSQL

**Before Production Deployment:**

```bash
# 1. Install PostgreSQL and psycopg2
pip install psycopg2-binary

# 2. Create PostgreSQL database
psql -U postgres
CREATE DATABASE gitstats;
CREATE USER gitstats_user WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE gitstats TO gitstats_user;

# 3. Export data from SQLite
python manage.py dumpdata --natural-foreign --natural-primary > data.json

# 4. Update environment variables
export ENVIRONMENT=production
export DB_NAME=gitstats
export DB_USER=gitstats_user
export DB_PASSWORD=secure_password
export DB_HOST=localhost
export DB_PORT=5432

# 5. Run migrations on PostgreSQL
python manage.py migrate

# 6. Import data
python manage.py loaddata data.json

# 7. Verify data integrity
python manage.py check
python manage.py test
```

## Compliance

### PostgreSQL (Production)
- **Performance**: Sub-500ms queries meet API response requirement
- **Concurrency**: MVCC handles 100+ concurrent users without blocking
- **Reliability**: Enterprise-grade ACID compliance and crash recovery
- **Scalability**: Horizontal scaling with read replicas for growth
- **Backup**: Point-in-time recovery and automated backups
- **Security**: SSL encryption and row-level security for compliance

### SQLite (Development Only)
- **Performance**: Sub-millisecond queries for development testing
- **Simplicity**: Zero configuration for rapid development iteration
- **Testing**: Fast test execution for CI/CD pipelines
- **NOT FOR PRODUCTION**: Concurrency limitations make it unsuitable for 100+ users

## Production Deployment Requirements

**CRITICAL**: PostgreSQL is **REQUIRED** for production deployment. SQLite is **NOT** production-ready.

**Before Production Launch:**
1. ✅ Set up PostgreSQL database server
2. ✅ Configure connection pooling (pgBouncer recommended)
3. ✅ Set up automated backups (pg_dump + WAL archiving)
4. ✅ Configure monitoring (pg_stat_statements, pgAdmin)
5. ✅ Migrate data from SQLite to PostgreSQL
6. ✅ Load test with 100+ concurrent users
7. ✅ Set up SSL/TLS encryption
8. ✅ Configure read replicas (if high availability required)

**Performance Targets:**
- Sub-500ms query response times (p95)
- 100+ concurrent users without degradation
- 99.9% uptime for authentication services

## References

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Django PostgreSQL Notes](https://docs.djangoproject.com/en/4.2/ref/databases/#postgresql-notes)
- [PostgreSQL Performance Tuning](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [pgBouncer Connection Pooling](https://www.pgbouncer.org/)
- [SQLite Documentation](https://www.sqlite.org/docs.html) (development only)
- [Django Database Configuration](https://docs.djangoproject.com/en/4.2/ref/settings/#databases)
- Backend PRD: `docs/backend/PRD.md`
- Related ADR: `ADR-001-backend-framework-django.md`
