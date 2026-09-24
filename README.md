# Quanta

A native Python and Jupyter notebook editor for macOS, built with SwiftUI and AppKit.

![Quanta showing a notebook, inline chart, outline, and live variables](docs/images/notebook.png)

- Edit notebooks and scripts with live completions and a shared Python console.
- Inspect DataFrames, arrays, and models; view matplotlib and interactive Plotly charts.
- Browse local databases and data files with read-only SQL.
- Review changes with built-in Git and export notebooks to Python, HTML, or PDF.

## Build and run

Requires **macOS 15+**, **Xcode 26+**, and **Python 3**.

```sh
git clone https://github.com/hashemwa/quanta-ide.git
cd quanta-ide
./scripts/quanta run
```

You can also open `Quanta.xcodeproj` in Xcode and run the **Quanta** scheme.
Select a Python environment in the toolbar and choose **Trust and Enable Python**
to run code in your workspace.

## Example

Install these packages in your selected environment:

```sh
python -m pip install numpy pandas matplotlib plotly scikit-learn
```

Open [Examples/showcase.ipynb](Examples/showcase.ipynb) and press **⌘R**.
It uses locally generated synthetic data to demonstrate tables, plots, math,
model inspection, and SQLite export.

Quanta uses its own Python bridge. Most IPython magics, shell escapes, and
Jupyter widgets are unsupported; see [notebook compatibility](docs/notebook-compatibility.md).

## Documentation

- [Releases](https://github.com/hashemwa/quanta-ide/releases)
- [Development and release packaging](docs/development.md)
- [Data browser](docs/data-browser.md)
- [Contributing](CONTRIBUTING.md)

[MIT License](LICENSE)
