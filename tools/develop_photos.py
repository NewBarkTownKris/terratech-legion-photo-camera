"""Desktop folder picker for developing TerraTech Legion photo masters."""

import argparse
from pathlib import Path
from queue import Empty, Queue
from threading import Event, Thread
import tkinter as tk
from tkinter import filedialog, ttk
from tkinter.scrolledtext import ScrolledText

from export_photo import FORMATS, develop, discover_shots
from photo_directory import selected_directory


LABELS = {"logc3": "ARRI LogC3 TIFF", "flog": "Fuji F-Log TIFF", "dng": "Linear DNG"}


def picker_start():
    try:
        configured = selected_directory()
        if configured.is_dir():
            return configured
    except (OSError, ValueError):
        pass
    pictures = Path.home() / "Pictures"
    return pictures if pictures.is_dir() else Path.home()


def develop_folder(folder, formats, events, stop):
    def report(message, *, error=False):
        events.put(("log", message))

    saved = kept = failed = checked = 0
    try:
        sources = discover_shots(folder)
        total = len(sources)
        for source in sources:
            if stop.is_set():
                break
            events.put(("photo", (checked, total, source.name)))
            written, existing, problem = develop(source, formats, report=report)
            saved += written
            kept += existing
            failed += int(problem)
            checked += 1
        summary = (f"Checked {checked} of {total} EXRs. Saved {saved} files. "
                   f"Kept {kept} existing. Failed photos: {failed}.") if total else "No EXRs found in this folder."
    except Exception as exc:
        # Surface worker errors in the window, including directory access failures.
        summary = f"Export stopped: {exc}"
    events.put(("done", (checked, summary)))


class PhotoDeveloper:
    def __init__(self, root, folder=None):
        self.root = root
        self.folder = tk.StringVar(value=str(folder) if folder is not None else "")
        self.status = tk.StringVar(value="Choose a folder and the files to create.")
        self.formats = {fmt: tk.BooleanVar(value=True) for fmt in FORMATS}
        self.events = Queue()
        self.stop = Event()
        self.running = False
        root.title("TerraTech Legion Photo Developer")
        root.minsize(530, 330)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        panel = ttk.Frame(root, padding=16)
        panel.grid(sticky="nsew")
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(5, weight=1)

        ttk.Label(panel, text="Folder containing EXRs").grid(row=0, column=0, sticky="w")
        self.choose = ttk.Button(panel, text="Choose folder…", command=self.pick)
        self.choose.grid(row=1, column=1, padx=(8, 0))
        ttk.Entry(panel, textvariable=self.folder, state="readonly").grid(row=1, column=0, sticky="ew")

        output = ttk.Frame(panel)
        output.grid(row=2, column=0, columnspan=2, sticky="w", pady=12)
        self.checks = []
        for fmt, var in self.formats.items():
            check = ttk.Checkbutton(output, text=LABELS[fmt], variable=var, command=self.controls)
            check.pack(side="left", padx=(0, 14))
            self.checks.append(check)
        self.start = ttk.Button(panel, text="Develop photos", command=self.run)
        self.start.grid(row=3, column=1, sticky="e")
        ttk.Label(panel, textvariable=self.status, wraplength=420).grid(row=3, column=0, sticky="w")
        self.progress = ttk.Progressbar(panel, mode="determinate")
        self.progress.grid(row=4, column=0, columnspan=2, sticky="ew", pady=(8, 10))
        self.log = ScrolledText(panel, width=70, height=8, wrap="word", state="disabled")
        self.log.grid(row=5, column=0, columnspan=2, sticky="nsew")
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.controls()
        if folder is None:
            root.after_idle(self.pick)

    def controls(self):
        for widget in (self.choose, *self.checks):
            widget.state(["disabled" if self.running else "!disabled"])
        ready = not self.running and self.folder.get() and any(var.get() for var in self.formats.values())
        self.start.state(["!disabled" if ready else "disabled"])

    def pick(self):
        previous = self.folder.get()
        initial = Path(previous) if previous and Path(previous).is_dir() else picker_start()
        chosen = filedialog.askdirectory(parent=self.root, title="Choose a folder of TerraTech Legion EXRs",
                                         initialdir=str(initial), mustexist=True)
        if chosen:
            self.folder.set(chosen)
            self.status.set("Ready to develop.")
            self.progress.configure(value=0)
        self.controls()

    def run(self):
        formats = tuple(fmt for fmt, var in self.formats.items() if var.get())
        if self.running or not self.folder.get() or not formats:
            return
        self.running = True
        self.controls()
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.status.set("Scanning folder…")
        self.progress.configure(value=0)
        Thread(target=develop_folder, args=(Path(self.folder.get()), formats, self.events, self.stop)).start()
        self.root.after(75, self.poll)

    def poll(self):
        while True:
            try:
                kind, value = self.events.get_nowait()
            except Empty:
                break
            if kind == "photo":
                checked, total, name = value
                self.progress.configure(value=checked, maximum=total)
                if not self.stop.is_set():
                    self.status.set(f"Photo {checked + 1} of {total} — {name}")
            elif kind == "log":
                self.log.configure(state="normal")
                self.log.insert("end", value + "\n")
                self.log.see("end")
                self.log.configure(state="disabled")
            elif kind == "done":
                checked, summary = value
                self.progress.configure(value=checked)
                self.status.set(summary)
                self.running = False
                self.controls()
                if self.stop.is_set():
                    self.root.destroy()
                return
        self.root.after(75, self.poll)

    def close(self):
        if self.running:
            self.stop.set()
            self.status.set("Finishing the current photo before closing…")
        else:
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", nargs="?", type=Path, help="Start with this folder selected")
    args = parser.parse_args()
    root = tk.Tk()
    PhotoDeveloper(root, args.folder)
    root.mainloop()


if __name__ == "__main__":
    main()
