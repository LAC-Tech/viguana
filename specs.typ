#title[Viguana]

= Product

I want a text editor, that works on the terminal, that has stuff I want built in, but also doesn't have to support any legacy cruft; a blank slate.

I also want to see if I can build a highly interactive and graphical application using "deterministic core, non-deterministic shell". The mixture of Tigerstyle, Naked Objects, Hexagon Architecture that makes so much sense in my head, but I've never tried using on a UI user app.

So this is partly to scratch an itch, and partly a learning exercise to further my craft.

== Users

If you're anything like me - and I know I am - you may like this editor. It is not meant to be an editor for every one. It's not an "editor framework" like neovim or emacs.

== Name

"Viguana" is a pretty rubbish play on Vi + Ziguana; it's a working name only.

= System

== Functionality

I'd like to replace my current neovim setup¸ which has:

- no neck pain (equivalent should be built in; no floating windows hack nonsense)
- fzf-lua
- LSP integration + autocomplete
- TreeSitter syntax highlighting
- leader keys
- Formatter integration
- nvim surround - love that tag based stuff
- a spell checker (though I would like my one to work consistently)

== Configurability

To forestall "what scripting language do I use?", I will aim to configure it with plain data files, like helix with it's toml config.

I'd also like to avoid locking in vi's keybinds. There should be default keybinds but everything should be re-assinable to something else.

== How modal editors work

I can reason about normal/visual/insert modes.

But it feels to me that normal mode has sub modes. like 'c' starts change mode, 'd' starts delete mode, etc.

== Milestones

=== Headless

Something very close to busy box vi functionality, but no real IO yet, all inside the core.

Testing it at this level ensures core subsumes as much functionality as possible.

=== Hello File


- Monochrome
- single buffer
- crashes after N inputs without save (fixed Piece Table)
- Usage: vig FILENAME. vig by itself makes a new file
- hjkl, cc, dd - cursor goes to start. no clipboard, so dd just deletes
- u undoes everything entered in insert mode, as well cc and dd.
- :w saves, and :q quits
- i enters insert mode, esc exits.
- backspace deletes characters in insert, enter adds a new line
- basic io-uring loop
- scrolling view

=== V2

Config file. Should be able to allocate a vertical slice of the terminal 80 chars wide, in the middle, like an inbuilt no-neck-pain.

=== V3, V4...

TBA. I think I want to be careful the order I code these in.

== Non-Goals

- OSes other than 64 bit linux. I'll keep the stuff that touches linux nicely separated from the core logic as a matter of architectural hygiene, but I am not going to waste braincells thinking about other OSes.
- Scripting. I will take data config files as far as I can.
- Feature parity with neovim, or all vim commands - only going to add the ones I use for now
- Windowing systems; no split pane, no floating windows. MAY have popups for LSP stuff, but everything else should just be a temp buffer.
- Working on every terminal emulator. I expect a bug free implementation of the ECMA-48 control codes. I will probably work around bugs in kitty (use it daily) and xterm (the basline), but that's about it.

= Technical

== Tech Stack

/ Language: Zig 0.16
/ Event Loop: io_uring
/ Config: ZON
/ Dependencies: TreeSitter, LSP (not sure what this needs yet)
/ UI: ECMA-48 Control Codes

I have not used Zig for a while, so I may have developed rose tinted gogles, but my impressions were 1. it's quite spartan 2. I was quite productive because there were fewer distractions/choices.

Rust brings up too many annoying questions. What do I use for io-uring? Where's the safety boundary? What config file format do I use? What colour knee socks should I buy? Zig is not great for exploratory programming; but I think I would rather explore in design instead of in code.

== Architecture

"Deterministic Core, Non-Deterministc Shell".

We want to maximise the amount of code that lives in a deterministic core. I see this taking the shape of a mealy machine; I think this most fits in with an io driven event loop, but I am not sure. Ideally inside loop we want to batch:

- writing to internal state
- submitting SQEs

This will be refined as we prototype.

=== Core

In memory, abstract representation of the entire editor and every file it has open.

== How To Represent Text

The "piece table" appeals to me alot as a WAL Enjoyer. It's also a good fit for systems programming where you are manging your own heap; Ropes seem quite complex here. #link("https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation")[Peng Lyu has a great article about using piece tables in VSCode], there were problems but 1) cross that bridge when we come to it 2) they have the constrained of needing to communicate between C++ and JS, I do not. If we properly isolate this from syscalls, we can just test this in headless mode and see what happens.

== Bulk Allocation

The idea of bulk allocating all memory needed for the core, ala Tigerbeetle, is appealing to me. Let's do some back of the envelop calculations.

Open Files: 256
Consecutive Edits/Undos: 4906
Piece/Span: 64 bits

That's under 8.4 megabytes; or 6 floppy disks. Of course god knows what we'd need once LSP and Treesitter gets added, but it seems like a decent starting point. I just started neovim, it allocated just under 50 megabytes across two processes. 64 megabytes for one process sounds good?

Also, this editor is for _me_. I don't have thousands of tabs open or edit 8 gb files.
