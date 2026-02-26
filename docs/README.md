# MEM Projection Website

This directory contains the GitHub Pages website for the MEM Projection project.

## Setup

To enable GitHub Pages for this site:

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Pages**
3. Under "Source", select **Deploy from a branch**
4. Select the branch (e.g., `main`) and `/docs` folder
5. Click **Save**

Your site will be published at: `https://hlakshmidevi10.github.io/mem-projection/`

## Local Development

To preview the site locally, you can use any static file server. For example:

```bash
# Using Python
cd docs
python -m http.server 8000

# Using Node.js (http-server)
npx http-server docs -p 8000
```

Then open `http://localhost:8000` in your browser.

## Files

- `index.html` - Main website content
- `styles.css` - Styling and responsive design
- `script.js` - Interactive features and animations
