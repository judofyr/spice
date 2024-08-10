import matplotlib.pyplot as plt
import numpy as np
import os
import sys

filename, title, outfile = sys.argv[1:]

data = [row.strip().split(",") for row in open(sys.argv[1])]

# `barh` prints from bottom to top.
data.reverse()

labels = [row[0] for row in data]
values = [float(row[1]) for row in data]

# https://github.com/system-fonts/modern-font-stacks#humanist
plt.rcParams["font.family"] = "Seravek, Gill Sans Nova, Ubuntu, Calibri, DejaVu Sans, source-sans-pro, sans-serif"
# This makes sure we don't embed the font into the SVG:
plt.rcParams['svg.fonttype'] = 'none'

plt.figure(figsize=(5, 2.7))
plt.title(title, fontdict={'fontweight': 'bold'}, pad=10)
plt.grid(axis='x', color='#ccc')
bars = plt.barh(labels, values, height=0.4)
plt.bar_label(bars, ["{:.2f} ns".format(value) for value in values], padding=3)
plt.xlabel("time per node [nanoseconds]", labelpad=10)

ax = plt.gca()
ax.set_axisbelow(True)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
# ax.spines['bottom'].set_visible(False)
# ax.tick_params(axis='x', colors='#ccc')
plt.tight_layout()

plt.savefig(outfile)
