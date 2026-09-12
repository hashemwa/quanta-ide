<h1 align="center">Quanta</h1>

<p align="center">A native workspace for Python and Jupyter notebooks on macOS.</p>
<p align="center"><sub>SwiftUI + AppKit · macOS 15+ · MIT licensed</sub></p>

![Python notebook with an inline plot and live variables in Quanta](docs/images/notebook.png)

## Explore, run, understand

- **Notebooks and scripts** — edit `.ipynb` and `.py` files with syntax highlighting, keyboard shortcuts, and a shared Python session.
- **Data you can inspect** — native DataFrame tables, a variable explorer, and an interactive console.
- **Plots beside your code** — inline matplotlib charts and interactive Plotly figures.
- **Git built in** — review diffs, stage changes, and commit. Notebook diffs focus on source, so rerunning cells stays out of the way.

![A pandas DataFrame displayed as a native table in Quanta](docs/images/dataframe.png)

## Get started

Build from source with **Xcode 26+**, **macOS 15+**, and **Python 3**:

```sh
git clone https://github.com/hashemwa/quanta-ide.git
cd quanta-ide
./scripts/quanta run
```

Or open `Quanta.xcodeproj` in Xcode and run the **Quanta** scheme.

Quanta discovers local Python environments automatically. Select yours in the toolbar.
For the sample notebook, install these packages in that environment:

```sh
python -m pip install numpy pandas matplotlib
```

Open `Examples/exploration.ipynb` and press **⌘R** to run it. The example uses synthetic data.
The Python bridge itself needs only the standard library.

| Shortcut | Action |
| :--- | :--- |
| ⌘↩ | Run cell |
| ⇧↩ | Run cell and advance |
| ⌘R | Run notebook or script |
| ⌘. | Interrupt execution |

## Contribute

Bug reports and focused pull requests are welcome. See [Contributing](CONTRIBUTING.md)
for the project conventions and [Development](docs/development.md) for architecture,
building, and release packaging.

```sh
./scripts/quanta test
```

[MIT License](LICENSE)
