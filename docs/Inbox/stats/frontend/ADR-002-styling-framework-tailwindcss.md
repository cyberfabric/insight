# ADR-002: Styling Framework Selection - TailwindCSS

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/frontend/PRD.md`  
**Related ADR**: `ADR-001-ui-framework-react.md`

## Context

The Git Stats Dashboard Frontend requires a styling solution that supports:
- Rapid UI development with consistent design system
- Mobile-responsive layouts (375px-1920px)
- Dark/light theme support
- Component-level styling without CSS conflicts
- Small production bundle size
- Easy customization for brand colors and spacing

The application includes:
- 15+ page views with complex layouts
- Data tables, charts, modals, and forms
- Mobile navigation drawer and responsive grids
- Theme toggle with user preference persistence

## Decision

We will use **TailwindCSS 3.4+** as the styling framework for the Git Stats Dashboard Frontend.

## Rationale

### Why TailwindCSS

1. **Utility-First Approach**: Rapid prototyping and development with utility classes directly in JSX, eliminating context switching between HTML and CSS files.

2. **Design System Built-In**: Consistent spacing scale (4px base), color palette, typography, and breakpoints ensure design consistency across 15+ pages.

3. **Responsive Design**: Mobile-first breakpoints (`sm:`, `md:`, `lg:`, `xl:`, `2xl:`) simplify responsive layouts for 375px-1920px range.

4. **Dark Mode Support**: Built-in `dark:` variant enables theme toggle with minimal configuration.

5. **Production Optimization**: PurgeCSS integration removes unused styles, resulting in ~10KB gzipped CSS (vs 100KB+ for traditional CSS frameworks).

6. **No CSS Conflicts**: Utility classes eliminate specificity wars and naming collisions common in traditional CSS.

7. **Developer Experience**: IntelliSense support in VS Code provides autocomplete for all utility classes.

8. **Customization**: `tailwind.config.js` enables brand color customization, custom spacing, and design token management.

### Alternatives Considered

#### CSS Modules
- **Pros**: Scoped styles, no global conflicts, works with any CSS preprocessor
- **Cons**: Requires separate CSS files, manual responsive design, no design system
- **Verdict**: Rejected due to slower development velocity and lack of built-in design system

#### Styled Components (CSS-in-JS)
- **Pros**: Dynamic styling, component-scoped, TypeScript support
- **Cons**: Runtime overhead, larger bundle size, slower initial render, no design system
- **Verdict**: Rejected due to performance concerns and runtime overhead

#### Material-UI (MUI)
- **Pros**: Complete component library, Material Design system, accessibility built-in
- **Cons**: Opinionated design, heavy bundle size (~300KB), difficult customization
- **Verdict**: Rejected due to bundle size and design constraints

#### Bootstrap 5
- **Pros**: Mature ecosystem, comprehensive components, familiar to developers
- **Cons**: jQuery legacy, opinionated markup, larger bundle size, harder customization
- **Verdict**: Rejected due to bundle size and customization limitations

#### Vanilla CSS
- **Pros**: No framework overhead, maximum control
- **Cons**: Manual responsive design, no design system, naming conventions required
- **Verdict**: Rejected due to development velocity and maintainability concerns

## Consequences

### Positive

- **Fast Development**: Utility classes enable rapid UI prototyping without leaving JSX
- **Small Bundle**: PurgeCSS removes unused styles, resulting in ~10KB production CSS
- **Consistency**: Built-in design system ensures consistent spacing, colors, and typography
- **Responsive**: Mobile-first breakpoints simplify responsive design
- **Theme Support**: Dark mode variant enables theme toggle with minimal code
- **Maintainability**: No CSS conflicts or specificity issues

### Negative

- **Learning Curve**: Team needs to learn utility class names (mitigated by IntelliSense)
- **Verbose HTML**: Long className strings can reduce readability (mitigated by component extraction)
- **Framework Lock-in**: Migrating to another CSS framework requires rewriting all styles

### Neutral

- **Custom Components**: Complex components may require `@apply` directive or component extraction
- **Design Tokens**: Custom colors and spacing defined in `tailwind.config.js`
- **Build Process**: Requires PostCSS integration in build pipeline

## Implementation Notes

### Configuration

```javascript
// tailwind.config.js
module.exports = {
  content: ['./src/**/*.{js,jsx,ts,tsx}'],
  darkMode: 'class', // Enable dark mode via class strategy
  theme: {
    extend: {
      colors: {
        primary: '#3B82F6',
        secondary: '#10B981',
        // Custom brand colors
      },
      spacing: {
        // Custom spacing if needed
      },
    },
  },
  plugins: [],
}
```

### Responsive Breakpoints

- `sm`: 640px (mobile landscape)
- `md`: 768px (tablet)
- `lg`: 1024px (desktop)
- `xl`: 1280px (large desktop)
- `2xl`: 1536px (extra large desktop)

### Dark Mode Implementation

```jsx
// Theme toggle component
<button onClick={() => document.documentElement.classList.toggle('dark')}>
  Toggle Theme
</button>

// Component with dark mode styles
<div className="bg-white dark:bg-gray-900 text-gray-900 dark:text-white">
  Content
</div>
```

### Component Extraction Pattern

For complex repeated patterns, extract to reusable components:

```jsx
// Button component
const Button = ({ children, variant = 'primary' }) => {
  const baseClasses = 'px-4 py-2 rounded-lg font-medium transition-colors';
  const variantClasses = {
    primary: 'bg-blue-600 hover:bg-blue-700 text-white',
    secondary: 'bg-gray-200 hover:bg-gray-300 text-gray-900',
  };
  
  return (
    <button className={`${baseClasses} ${variantClasses[variant]}`}>
      {children}
    </button>
  );
};
```

## Compliance

- **Performance**: ~10KB gzipped CSS supports sub-3-second load time requirement
- **Mobile**: Responsive utilities support 375px-1920px layouts
- **Theme**: Dark mode variant enables theme toggle requirement
- **Accessibility**: Utility classes don't prevent semantic HTML and ARIA attributes

## References

- [TailwindCSS Documentation](https://tailwindcss.com/docs)
- [TailwindCSS Dark Mode](https://tailwindcss.com/docs/dark-mode)
- [TailwindCSS Responsive Design](https://tailwindcss.com/docs/responsive-design)
- Frontend PRD: `docs/frontend/PRD.md`
- Related ADR: `ADR-001-ui-framework-react.md`
