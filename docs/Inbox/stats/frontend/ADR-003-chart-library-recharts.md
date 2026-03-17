# ADR-003: Chart Visualization Library Selection - Recharts

**Status**: Accepted  
**Date**: 2024-03-13  
**Decision Makers**: Engineering Team  
**Related PRD**: `docs/frontend/PRD.md`  
**Related ADR**: `ADR-001-ui-framework-react.md`

## Context

The Git Stats Dashboard Frontend requires a charting library to visualize analytics data:
- Time-series charts (AI LOC trends, commit activity, PR velocity)
- Bar charts (contributor breakdown, department metrics)
- Pie charts (language distribution, AI tool adoption)
- Interactive features (tooltips, legends, filtering, zoom)
- Responsive design for mobile and desktop
- Dark/light theme support
- Performance for large datasets (thousands of data points)

The application includes:
- Dashboard page with 4+ charts
- AI Adoption page with 6+ charts
- Bitbucket page with 5+ charts
- Reports page with trend visualizations
- Real-time filtering across all charts

## Decision

We will use **Recharts 2.15+** as the chart visualization library for the Git Stats Dashboard Frontend.

## Rationale

### Why Recharts

1. **React-Native**: Built specifically for React using composable components, not a wrapper around D3 or Canvas.

2. **Declarative API**: Charts defined as JSX components with props, matching React's component model:
   ```jsx
   <LineChart data={data}>
     <XAxis dataKey="date" />
     <YAxis />
     <Line dataKey="aiLOC" stroke="#3B82F6" />
     <Tooltip />
   </LineChart>
   ```

3. **Responsive by Default**: `ResponsiveContainer` automatically resizes charts for mobile/desktop layouts.

4. **Customization**: Full control over colors, styles, tooltips, and legends to match design system.

5. **Performance**: SVG-based rendering handles thousands of data points efficiently with animation support.

6. **TypeScript Support**: Comprehensive TypeScript definitions for all chart types and props.

7. **Bundle Size**: ~95KB gzipped (reasonable for feature-rich charting library).

8. **Active Maintenance**: 23k+ GitHub stars, regular updates, large community.

9. **Theme Integration**: Easy integration with TailwindCSS colors and dark mode.

### Alternatives Considered

#### Chart.js
- **Pros**: Mature, Canvas-based (faster for large datasets), extensive documentation
- **Cons**: Imperative API (not React-native), requires wrapper library (react-chartjs-2), less customizable
- **Verdict**: Rejected due to imperative API and poor React integration

#### Victory
- **Pros**: React-native, composable, animation support
- **Cons**: Larger bundle size (~150KB), more complex API, steeper learning curve
- **Verdict**: Rejected due to bundle size and API complexity

#### D3.js
- **Pros**: Maximum flexibility, powerful data transformations, industry standard
- **Cons**: Imperative API, steep learning curve, manual React integration, large bundle
- **Verdict**: Rejected due to development velocity and learning curve

#### Nivo
- **Pros**: React-native, beautiful defaults, responsive, TypeScript support
- **Cons**: Larger bundle size (~120KB), less customization, smaller community
- **Verdict**: Rejected due to bundle size and customization limitations

#### Apache ECharts
- **Pros**: Feature-rich, excellent performance, large dataset support
- **Cons**: Imperative API, requires wrapper, large bundle (~300KB), complex configuration
- **Verdict**: Rejected due to bundle size and API complexity

#### Plotly.js
- **Pros**: Scientific visualization, 3D charts, extensive chart types
- **Cons**: Very large bundle (~1MB), overkill for business dashboards, imperative API
- **Verdict**: Rejected due to excessive bundle size

## Consequences

### Positive

- **Developer Experience**: Declarative JSX API matches React component model
- **Customization**: Full control over chart appearance and behavior
- **Responsive**: Built-in responsive container for mobile/desktop
- **Performance**: SVG rendering handles dashboard requirements efficiently
- **Theme Support**: Easy integration with TailwindCSS and dark mode
- **TypeScript**: Comprehensive type definitions improve development experience

### Negative

- **Bundle Size**: ~95KB gzipped adds to initial load (mitigated by code splitting)
- **Large Datasets**: SVG rendering may struggle with 10,000+ data points (mitigated by data sampling)
- **Animation Performance**: Complex animations may impact performance on low-end devices

### Neutral

- **Learning Curve**: Team needs to learn Recharts API (relatively simple)
- **Custom Charts**: Complex visualizations may require custom components
- **Accessibility**: Requires manual ARIA labels for screen reader support

## Implementation Notes

### Basic Chart Pattern

```jsx
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

const AILOCChart = ({ data }) => {
  return (
    <ResponsiveContainer width="100%" height={400}>
      <LineChart data={data}>
        <CartesianGrid strokeDasharray="3 3" />
        <XAxis dataKey="date" />
        <YAxis />
        <Tooltip />
        <Legend />
        <Line 
          type="monotone" 
          dataKey="aiLOC" 
          stroke="#3B82F6" 
          strokeWidth={2}
          dot={false}
        />
      </LineChart>
    </ResponsiveContainer>
  );
};
```

### Dark Mode Integration

```jsx
const CustomTooltip = ({ active, payload }) => {
  if (!active || !payload) return null;
  
  return (
    <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 p-3 rounded shadow-lg">
      <p className="text-gray-900 dark:text-white">
        {payload[0].value} LOC
      </p>
    </div>
  );
};

<LineChart data={data}>
  <Tooltip content={<CustomTooltip />} />
</LineChart>
```

### Performance Optimization

```jsx
// Data sampling for large datasets
const sampleData = (data, maxPoints = 1000) => {
  if (data.length <= maxPoints) return data;
  const step = Math.ceil(data.length / maxPoints);
  return data.filter((_, index) => index % step === 0);
};

// Disable animations for large datasets
<LineChart data={sampleData(data)} isAnimationActive={data.length < 1000}>
  {/* ... */}
</LineChart>
```

### Responsive Breakpoints

```jsx
// Adjust chart height based on screen size
const useChartHeight = () => {
  const [height, setHeight] = useState(400);
  
  useEffect(() => {
    const updateHeight = () => {
      setHeight(window.innerWidth < 768 ? 250 : 400);
    };
    
    window.addEventListener('resize', updateHeight);
    updateHeight();
    
    return () => window.removeEventListener('resize', updateHeight);
  }, []);
  
  return height;
};
```

## Compliance

- **Performance**: SVG rendering supports sub-3-second load time with data sampling
- **Mobile**: ResponsiveContainer supports 375px-1920px layouts
- **Theme**: Custom tooltips and colors support dark/light theme requirement
- **Accessibility**: Requires manual ARIA labels and keyboard navigation support

## References

- [Recharts Documentation](https://recharts.org/)
- [Recharts Examples](https://recharts.org/en-US/examples)
- [Recharts TypeScript](https://recharts.org/en-US/api)
- Frontend PRD: `docs/frontend/PRD.md`
- Related ADR: `ADR-001-ui-framework-react.md`
