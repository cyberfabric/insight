# ADR-004: Type System Selection - TypeScript

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/frontend/PRD.md`  
**Related ADR**: `ADR-001-ui-framework-react.md`

## Context

The Git Stats Dashboard Frontend requires a type system to ensure code quality and maintainability:
- Type safety for complex data structures (commits, PRs, users, filters)
- IDE support with autocomplete and refactoring
- Early error detection during development
- Self-documenting code for team collaboration
- Integration with React, Recharts, and TailwindCSS
- Support for 90%+ test coverage requirement

The application handles:
- 30+ filter options with complex state management
- Multiple data types (commits, PRs, users, AI metrics)
- API contracts with backend REST endpoints
- Component props across 15+ page views
- Utility functions for data transformation

## Decision

We will use **TypeScript 4.9+** as the type system for the Git Stats Dashboard Frontend.

## Rationale

### Why TypeScript

1. **Type Safety**: Static type checking catches errors at compile-time before they reach production:
   ```typescript
   interface Commit {
     sha: string;
     author: string;
     date: string;
     linesAdded: number;
     linesDeleted: number;
     aiAssisted: boolean;
   }
   
   // Compile error if wrong type passed
   const processCommit = (commit: Commit) => { /* ... */ };
   ```

2. **IDE Support**: IntelliSense provides autocomplete, parameter hints, and inline documentation, improving developer productivity by 20-30%.

3. **Refactoring Confidence**: Type system enables safe refactoring across codebase. Renaming properties or functions updates all references automatically.

4. **Self-Documenting**: Type definitions serve as inline documentation, reducing need for separate API documentation.

5. **React Integration**: First-class support for React with `@types/react`:
   ```typescript
   interface FilterBarProps {
     filters: FilterState;
     onFilterChange: (filters: FilterState) => void;
   }
   
   const FilterBar: React.FC<FilterBarProps> = ({ filters, onFilterChange }) => {
     // TypeScript ensures correct prop usage
   };
   ```

6. **API Contract Enforcement**: Type definitions ensure frontend matches backend API contracts:
   ```typescript
   interface APIResponse<T> {
     data: T;
     status: number;
     message?: string;
   }
   
   const fetchCommits = async (): Promise<APIResponse<Commit[]>> => {
     // Type-safe API calls
   };
   ```

7. **Error Prevention**: Catches common errors:
   - Null/undefined access
   - Missing object properties
   - Wrong function arguments
   - Type mismatches in operations

8. **Gradual Adoption**: Can be adopted incrementally with `.js` and `.ts` files coexisting.

9. **Community Standard**: 90%+ of React projects use TypeScript (2024 State of JS survey).

### Alternatives Considered

#### JavaScript (Vanilla)
- **Pros**: No build step, no learning curve, maximum flexibility
- **Cons**: No type safety, runtime errors, poor IDE support, difficult refactoring
- **Verdict**: Rejected due to code quality and maintainability concerns

#### Flow
- **Pros**: Similar to TypeScript, gradual typing, Facebook-backed
- **Cons**: Smaller community, fewer type definitions, declining adoption, less IDE support
- **Verdict**: Rejected due to declining community support and ecosystem

#### JSDoc with Type Checking
- **Pros**: No build step, works with vanilla JS, gradual adoption
- **Cons**: Verbose syntax, limited type features, poor IDE support, inconsistent enforcement
- **Verdict**: Rejected due to verbosity and limited type system features

#### ReScript (formerly ReasonML)
- **Pros**: Strong type system, functional programming, fast compilation
- **Cons**: Steep learning curve, small community, limited React ecosystem, syntax unfamiliar
- **Verdict**: Rejected due to team expertise gap and ecosystem immaturity

## Consequences

### Positive

- **Error Prevention**: Catch 15-20% of bugs at compile-time before runtime
- **Developer Productivity**: IDE autocomplete and refactoring improve velocity
- **Code Quality**: Type safety enforces consistent data structures
- **Maintainability**: Self-documenting code reduces onboarding time
- **Refactoring Safety**: Type system enables confident large-scale refactoring
- **API Contracts**: Type definitions ensure frontend/backend alignment

### Negative

- **Build Step**: Requires TypeScript compiler (tsc) in build pipeline
- **Learning Curve**: Team needs TypeScript knowledge (mitigated by JavaScript similarity)
- **Development Overhead**: Writing type definitions adds initial development time
- **Strict Mode Challenges**: Strict null checks require careful handling of optional values

### Neutral

- **Type Definitions**: Third-party libraries require `@types/*` packages (most popular libraries have them)
- **Configuration**: `tsconfig.json` requires careful configuration for optimal strictness
- **Gradual Adoption**: Can start with loose types and increase strictness over time

## Implementation Notes

### TypeScript Configuration

```json
// tsconfig.json
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "jsx": "react-jsx",
    "module": "ESNext",
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true
  },
  "include": ["src"]
}
```

### Core Type Definitions

```typescript
// src/types.ts

// Filter state
export interface FilterState {
  dateRange: [Date, Date];
  users: string[];
  organizations: string[];
  repositories: string[];
  languages: string[];
  aiTools: AITool[];
  excludeLargeCommits: boolean;
  excludeMergeCommits: boolean;
}

// Commit data
export interface Commit {
  sha: string;
  author: string;
  authorEmail: string;
  date: string;
  message: string;
  linesAdded: number;
  linesDeleted: number;
  linesModified: number;
  filesChanged: string[];
  aiAssisted: boolean;
  aiTool?: AITool;
  repository: string;
}

// User data
export interface User {
  id: string;
  username: string;
  email: string;
  role: 'admin' | 'user';
  permissions: {
    pages: string[];
    charts: string[];
  };
}

// API response wrapper
export interface APIResponse<T> {
  data: T;
  status: number;
  message?: string;
  pagination?: {
    page: number;
    pageSize: number;
    total: number;
  };
}
```

### React Component Typing

```typescript
// Functional component with props
interface DashboardProps {
  filters: FilterState;
  onFilterChange: (filters: FilterState) => void;
}

export const Dashboard: React.FC<DashboardProps> = ({ filters, onFilterChange }) => {
  // Component implementation
};

// Custom hooks
export const useFilters = (): [FilterState, (filters: FilterState) => void] => {
  const [filters, setFilters] = useState<FilterState>(defaultFilters);
  return [filters, setFilters];
};
```

### Strict Null Checking

```typescript
// Handle optional values safely
interface UserDetailsModalProps {
  user: User | null;
  onClose: () => void;
}

export const UserDetailsModal: React.FC<UserDetailsModalProps> = ({ user, onClose }) => {
  if (!user) {
    return null; // Early return for null case
  }
  
  // TypeScript knows user is not null here
  return <div>{user.username}</div>;
};
```

## Compliance

- **Code Quality**: Type safety supports 90%+ test coverage requirement
- **Maintainability**: Self-documenting code improves long-term maintainability
- **Performance**: TypeScript compiles to optimized JavaScript with no runtime overhead
- **Team Velocity**: IDE support and refactoring tools improve development speed

## References

- [TypeScript Documentation](https://www.typescriptlang.org/docs/)
- [React TypeScript Cheatsheet](https://react-typescript-cheatsheet.netlify.app/)
- [TypeScript Deep Dive](https://basarat.gitbook.io/typescript/)
- Frontend PRD: `docs/frontend/PRD.md`
- Related ADR: `ADR-001-ui-framework-react.md`
