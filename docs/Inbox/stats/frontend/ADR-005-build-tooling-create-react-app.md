# ADR-005: Build Tooling Selection - Create React App

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/frontend/PRD.md`  
**Related ADR**: `ADR-001-ui-framework-react.md`, `ADR-004-type-system-typescript.md`

## Context

The Git Stats Dashboard Frontend requires build tooling to:
- Compile TypeScript to JavaScript
- Bundle React components with code splitting
- Process TailwindCSS with PostCSS
- Optimize production builds (minification, tree shaking)
- Provide development server with hot module replacement (HMR)
- Support testing with Jest and React Testing Library
- Enable linting with ESLint
- Maintain <500KB gzipped initial bundle size

The application needs:
- Fast development iteration cycles
- Production-ready optimization
- Code splitting for 15+ lazy-loaded pages
- Source maps for debugging
- Environment variable management
- Testing infrastructure

## Decision

We will use **Create React App (CRA) 5.0+** with **React Scripts 5.0+** as the build tooling for the Git Stats Dashboard Frontend.

## Rationale

### Why Create React App

1. **Zero Configuration**: Pre-configured webpack, Babel, ESLint, Jest, and PostCSS out of the box. No build configuration needed.

2. **TypeScript Support**: Built-in TypeScript compilation without additional configuration.

3. **Code Splitting**: Automatic code splitting with React.lazy() and dynamic imports:
   ```javascript
   const Dashboard = React.lazy(() => import('./views/Dashboard'));
   ```

4. **Development Experience**: 
   - Fast refresh (HMR) for instant feedback
   - Development server with proxy support for backend API
   - Source maps for debugging
   - Error overlay in browser

5. **Production Optimization**:
   - Minification with Terser
   - Tree shaking to remove unused code
   - Asset optimization (images, fonts)
   - Cache-busting with content hashes
   - Gzip compression

6. **Testing Infrastructure**: Jest and React Testing Library pre-configured with coverage reporting.

7. **Maintenance**: Maintained by React team, regular updates, security patches.

8. **Team Familiarity**: Standard tool in React ecosystem, minimal learning curve.

9. **Ejection Option**: Can eject to customize webpack configuration if needed (though not recommended).

### Alternatives Considered

#### Vite
- **Pros**: Extremely fast dev server (ESBuild), faster builds, modern tooling, smaller config
- **Cons**: Newer tool (less mature), different dev/prod bundlers, potential compatibility issues
- **Verdict**: Rejected due to team preference for proven stability over cutting-edge speed

#### Next.js
- **Pros**: Server-side rendering, API routes, file-based routing, image optimization
- **Cons**: Overkill for SPA, SSR not needed, opinionated structure, larger bundle
- **Verdict**: Rejected because PRD specifies client-side SPA, not SSR

#### Webpack (Manual Setup)
- **Pros**: Maximum control, custom optimization, no abstraction
- **Cons**: Complex configuration, maintenance burden, time-consuming setup
- **Verdict**: Rejected due to development velocity and maintenance overhead

#### Parcel
- **Pros**: Zero configuration, fast builds, automatic transforms
- **Cons**: Less control, smaller ecosystem, fewer plugins, less mature
- **Verdict**: Rejected due to ecosystem maturity and team familiarity

#### Rollup
- **Pros**: Excellent for libraries, tree shaking, ES modules
- **Cons**: Better for libraries than apps, manual configuration, smaller ecosystem
- **Verdict**: Rejected because optimized for library builds, not applications

#### esbuild (Direct)
- **Pros**: Extremely fast, written in Go, minimal config
- **Cons**: Limited plugin ecosystem, no HMR, immature for production apps
- **Verdict**: Rejected due to lack of production-ready features

## Consequences

### Positive

- **Fast Setup**: Zero configuration gets project running in minutes
- **Developer Experience**: Fast refresh and error overlay improve iteration speed
- **Production Ready**: Optimized builds meet <500KB bundle size requirement
- **Testing**: Jest and React Testing Library enable 90%+ coverage target
- **Maintenance**: React team maintains tooling, regular updates
- **Team Velocity**: Standard tooling reduces onboarding time

### Negative

- **Limited Customization**: Difficult to customize webpack without ejecting
- **Bundle Size**: Slightly larger than custom webpack setup (~10-20KB overhead)
- **Build Speed**: Slower than Vite for large projects (acceptable for current size)
- **Ejection Risk**: Ejecting makes future updates difficult

### Neutral

- **Webpack Under Hood**: Uses webpack 5, which is mature but not cutting-edge
- **Environment Variables**: Requires `REACT_APP_` prefix for custom env vars
- **Proxy Configuration**: Backend API proxy configured in `package.json`

## Implementation Notes

### Project Structure

```
git-stats-frontend/
├── public/
│   ├── index.html
│   └── favicon.ico
├── src/
│   ├── components/
│   ├── views/
│   ├── context/
│   ├── services/
│   ├── types.ts
│   ├── App.tsx
│   └── index.tsx
├── package.json
├── tsconfig.json
└── tailwind.config.js
```

### Package.json Scripts

```json
{
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build",
    "test": "react-scripts test",
    "test:coverage": "react-scripts test --coverage --watchAll=false",
    "eject": "react-scripts eject"
  }
}
```

### Environment Variables

```bash
# .env.development
REACT_APP_API_URL=http://localhost:8000
REACT_APP_ANALYTICS_ENABLED=true

# .env.production
REACT_APP_API_URL=https://api.gitstats.example.com
REACT_APP_ANALYTICS_ENABLED=true
```

```typescript
// Usage in code
const API_URL = process.env.REACT_APP_API_URL;
```

### Backend API Proxy

```json
// package.json
{
  "proxy": "http://localhost:8000"
}
```

### Code Splitting Pattern

```typescript
// App.tsx
import React, { Suspense } from 'react';

const Dashboard = React.lazy(() => import('./views/Dashboard'));
const AIAdoption = React.lazy(() => import('./views/AIAdoption'));
const Users = React.lazy(() => import('./views/Users'));

function App() {
  return (
    <Suspense fallback={<LoadingSpinner />}>
      <Routes>
        <Route path="/dashboard" element={<Dashboard />} />
        <Route path="/ai-adoption" element={<AIAdoption />} />
        <Route path="/users" element={<Users />} />
      </Routes>
    </Suspense>
  );
}
```

### Production Build Optimization

```bash
# Build for production
npm run build

# Output structure
build/
├── static/
│   ├── js/
│   │   ├── main.[hash].js       # Main bundle
│   │   ├── [page].[hash].js     # Lazy-loaded pages
│   │   └── runtime.[hash].js    # Webpack runtime
│   └── css/
│       └── main.[hash].css      # Compiled CSS
└── index.html
```

### Bundle Analysis

```bash
# Install bundle analyzer
npm install --save-dev source-map-explorer

# Add script to package.json
"analyze": "source-map-explorer 'build/static/js/*.js'"

# Run analysis
npm run build
npm run analyze
```

## Compliance

- **Performance**: Code splitting and optimization support <500KB initial bundle requirement
- **Development**: Fast refresh enables rapid iteration for development velocity
- **Testing**: Jest and React Testing Library support 90%+ coverage requirement
- **Production**: Minification and tree shaking optimize for sub-3-second load time

## Migration Path

If CRA limitations become blocking, migration options:
1. **Vite**: Modern alternative with faster builds
2. **Custom Webpack**: Eject and customize configuration
3. **Next.js**: If SSR becomes requirement

Migration should only be considered if:
- Build times exceed 5 minutes
- Bundle size cannot be reduced below 500KB
- Custom webpack plugins are absolutely required

## References

- [Create React App Documentation](https://create-react-app.dev/)
- [React Scripts GitHub](https://github.com/facebook/create-react-app)
- [Code Splitting Guide](https://create-react-app.dev/docs/code-splitting/)
- Frontend PRD: `docs/frontend/PRD.md`
- Related ADR: `ADR-001-ui-framework-react.md`, `ADR-004-type-system-typescript.md`
