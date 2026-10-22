// Only this app-owned script and the pinned runtime are evaluated by WebKit.
// Diagram source is a callJavaScript argument, never JavaScript or HTML source.
globalThis.renderRemoteCoderDiagram = async function (source, dark, highContrast) {
  const colors = dark
    ? { background: '#171a21', foreground: '#f0f2f7', surface: '#253344', border: '#89b4e8', line: '#acb8cc', secondary: '#293c37', tertiary: '#393144' }
    : { background: '#fbfcfe', foreground: '#1b283b', surface: '#edf3fc', border: '#547aaa', line: '#51647d', secondary: '#edf6f0', tertiary: '#f3eff9' };
  const container = document.getElementById('diagram');
  container.replaceChildren();
  document.body.style.background = colors.background;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    maxTextSize: 32768,
    maxEdges: 250,
    suppressErrorRendering: true,
    htmlLabels: false,
    layout: 'dagre',
    fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
    theme: 'base',
    // Diagram-level frontmatter/directives cannot weaken the host policy.
    secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
      'suppressErrorRendering', 'htmlLabels', 'dompurifyConfig', 'theme',
      'themeVariables', 'themeCSS', 'fontFamily', 'flowchart', 'layout'],
    flowchart: { htmlLabels: false, useMaxWidth: false, curve: 'basis', padding: 16 },
    themeVariables: {
      darkMode: dark,
      background: colors.background,
      primaryColor: colors.surface,
      primaryTextColor: colors.foreground,
      primaryBorderColor: highContrast ? colors.foreground : colors.border,
      secondaryColor: colors.secondary,
      secondaryTextColor: colors.foreground,
      secondaryBorderColor: colors.border,
      tertiaryColor: colors.tertiary,
      tertiaryTextColor: colors.foreground,
      tertiaryBorderColor: colors.border,
      lineColor: highContrast ? colors.foreground : colors.line,
      textColor: colors.foreground,
      mainBkg: colors.surface,
      nodeBorder: colors.border,
      clusterBkg: colors.secondary,
      clusterBorder: colors.border,
      edgeLabelBackground: colors.background,
      actorBkg: colors.surface,
      actorBorder: colors.border,
      actorTextColor: colors.foreground,
      actorLineColor: colors.line,
      signalColor: colors.foreground,
      signalTextColor: colors.foreground,
      noteBkgColor: colors.tertiary,
      noteTextColor: colors.foreground,
      noteBorderColor: colors.border,
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      fontSize: '16px'
    }
  });
  try {
    const { svg } = await mermaid.render('rc-mermaid', source);
    if (svg.length > 2 * 1024 * 1024) throw new Error('This diagram is too large to preview.');
    container.innerHTML = svg;
    const image = container.querySelector('svg');
    if (!image) throw new Error('Mermaid did not produce a diagram.');
    // Defense in depth; diagrams are illustrations, not navigation or controls.
    if (image.querySelector('image, img, iframe, object, embed, video, audio')) {
      throw new Error('External images and embedded media are not supported in diagrams.');
    }
    image.querySelectorAll('a').forEach(link => link.replaceWith(...link.childNodes));
    image.querySelectorAll('script, animate, animateTransform, set').forEach(node => node.remove());
    image.querySelectorAll('*').forEach(node => {
      for (const attribute of [...node.attributes]) {
        if (/^on/i.test(attribute.name)) node.removeAttribute(attribute.name);
      }
    });
    const staticStyle = document.createElementNS('http://www.w3.org/2000/svg', 'style');
    staticStyle.textContent = 'svg,svg *{animation:none!important;transition:none!important}';
    image.append(staticStyle);
    const bounds = image.viewBox.baseVal;
    const width = bounds.width, height = bounds.height;
    if (![width, height].every(value => Number.isFinite(value) && value > 0 && value <= 20000)) {
      throw new Error('This diagram exceeds the preview dimensions.');
    }
    image.style.maxWidth = 'none';
    image.style.width = width + 'px';
    image.style.height = height + 'px';
    // Store a self-contained vector document; no runtime is needed in the viewer.
    const labels = [...new Set([...image.querySelectorAll('text, .nodeLabel, .edgeLabel')]
      .map(node => node.textContent.trim()).filter(Boolean))].slice(0, 24).join('; ');
    return {
      svg: new XMLSerializer().serializeToString(image), width, height,
      title: image.querySelector('title')?.textContent || 'Mermaid diagram',
      description: image.querySelector('desc')?.textContent || (labels ? 'Diagram labels: ' + labels.slice(0, 600) : ''),
      background: colors.background
    };
  } catch (error) {
    container.replaceChildren();
    throw new Error(String(error?.message || error).slice(0, 600));
  }
};
