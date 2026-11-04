//! zigsh — um shell minimalista para Linux escrito em Zig 0.16.x.
//!
//! Funcionalidades:
//!   * ciclo REPL com prompt dinâmico (diretório atual) e saída com EOF (Ctrl+D);
//!   * tokenização com suporte a aspas simples/duplas e escapes;
//!   * redirecionamentos `>` (stdout), `2>` (stderr) e `<` (stdin);
//!   * execução em segundo plano com `&` no final da linha;
//!   * pipelines com `|` (quantos estágios forem necessários);
//!   * comandos internos: cd, pwd, help, exit (e jobs, como extra).
//!
//! As seções do código estão marcadas com os mesmos números dos TODOs do
//! esqueleto fornecido no enunciado (TODO 1 … TODO 8).

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const StdIo = std.process.SpawnOptions.StdIo;

const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_posix = !is_windows and native_os != .wasi;

// ============================================================================
// Estruturas de dados do parser
// ============================================================================

/// Um comando simples (um estágio de pipeline) já analisado.
const ParsedCommand = struct {
    allocator: Allocator,
    args: std.ArrayList([]const u8) = .empty,
    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    is_background: bool = false,

    pub fn init(allocator: Allocator) ParsedCommand {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ParsedCommand) void {
        self.args.deinit(self.allocator);
    }
};

/// Uma linha completa: um ou mais comandos ligados por `|`.
const Pipeline = struct {
    commands: std.ArrayList(ParsedCommand) = .empty,
    is_background: bool = false,

    pub fn deinit(self: *Pipeline, allocator: Allocator) void {
        for (self.commands.items) |*cmd| cmd.deinit();
        self.commands.deinit(allocator);
    }
};

const TokenKind = enum {
    word,
    pipe, // |
    redirect_in, // <
    redirect_out, // >
    redirect_err, // 2>
    background, // &
};

const Token = struct {
    kind: TokenKind,
    text: []const u8 = "",
};

const ParseError = error{
    UnterminatedQuote,
    MissingRedirectTarget,
    EmptyCommand,
    MisplacedBackground,
} || Allocator.Error;

fn describeParseError(err: ParseError) []const u8 {
    return switch (err) {
        error.UnterminatedQuote => "aspas não fechadas",
        error.MissingRedirectTarget => "esperado um nome de arquivo após o operador de redirecionamento",
        error.EmptyCommand => "comando vazio (verifique o uso de '|', '&' ou redirecionamentos)",
        error.MisplacedBackground => "'&' só é permitido no final da linha",
        error.OutOfMemory => "memória insuficiente",
    };
}

// ============================================================================
// TODO 3 (parte 1): Tokenização
// ============================================================================

/// Quebra a linha em tokens. O delimitador principal é o espaço (e tabulação).
/// Operadores (`|`, `<`, `>`, `2>`, `&`) são reconhecidos mesmo sem espaços
/// ao redor (ex.: `ls>saida.txt`), exceto quando estão entre aspas.
///
/// Regras de aspas (semelhantes às do sh):
///   * '...'  conteúdo literal;
///   * "..."  permite os escapes \" \\ \$ \` e também \n e \t (quebra de linha
///            e tabulação), para que `echo "a\nb"` produza duas linhas;
///   * \x     fora de aspas torna o caractere x literal;
///   * #      no início de uma palavra inicia um comentário até o fim da linha.
///
/// O texto das palavras é alocado em `allocator` (normalmente uma arena
/// liberada a cada iteração do REPL).
fn tokenize(allocator: Allocator, line: []const u8) ParseError![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer {
        for (tokens.items) |t| if (t.kind == .word) allocator.free(t.text);
        tokens.deinit(allocator);
    }

    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);
    // `in_word` fica verdadeiro assim que uma palavra começa — inclusive uma
    // palavra vazia entre aspas (""), que é um argumento válido.
    var in_word = false;
    // `quoted` impede que um "2" escapado/entre aspas vire o operador `2>`.
    var quoted = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                try flushWord(allocator, &tokens, &word, &in_word, &quoted);
            },
            '|', '&', '<' => {
                try flushWord(allocator, &tokens, &word, &in_word, &quoted);
                const kind: TokenKind = switch (c) {
                    '|' => .pipe,
                    '&' => .background,
                    '<' => .redirect_in,
                    else => unreachable,
                };
                try tokens.append(allocator, .{ .kind = kind });
            },
            '>' => {
                if (in_word and !quoted and std.mem.eql(u8, word.items, "2")) {
                    // "2>" — redirecionamento de stderr.
                    word.clearRetainingCapacity();
                    in_word = false;
                    try tokens.append(allocator, .{ .kind = .redirect_err });
                } else {
                    try flushWord(allocator, &tokens, &word, &in_word, &quoted);
                    try tokens.append(allocator, .{ .kind = .redirect_out });
                }
            },
            '\'' => {
                in_word = true;
                quoted = true;
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse
                    return error.UnterminatedQuote;
                try word.appendSlice(allocator, line[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                quoted = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= line.len) return error.UnterminatedQuote;
                    const d = line[i];
                    if (d == '"') break;
                    if (d == '\\' and i + 1 < line.len) {
                        i += 1;
                        switch (line[i]) {
                            'n' => try word.append(allocator, '\n'),
                            't' => try word.append(allocator, '\t'),
                            '\\', '"', '$', '`' => try word.append(allocator, line[i]),
                            else => try word.appendSlice(allocator, &.{ '\\', line[i] }),
                        }
                    } else {
                        try word.append(allocator, d);
                    }
                }
            },
            '\\' => {
                // Uma barra invertida sozinha no fim da linha é ignorada.
                if (i + 1 < line.len) {
                    in_word = true;
                    quoted = true;
                    i += 1;
                    try word.append(allocator, line[i]);
                }
            },
            '#' => {
                if (in_word) {
                    try word.append(allocator, c);
                } else {
                    break; // comentário: ignora o resto da linha
                }
            },
            else => {
                in_word = true;
                try word.append(allocator, c);
            },
        }
    }
    try flushWord(allocator, &tokens, &word, &in_word, &quoted);

    return tokens.toOwnedSlice(allocator);
}

fn flushWord(
    allocator: Allocator,
    tokens: *std.ArrayList(Token),
    word: *std.ArrayList(u8),
    in_word: *bool,
    quoted: *bool,
) Allocator.Error!void {
    if (!in_word.*) return;
    const text = try allocator.dupe(u8, word.items);
    errdefer allocator.free(text);
    try tokens.append(allocator, .{ .kind = .word, .text = text });
    word.clearRetainingCapacity();
    in_word.* = false;
    quoted.* = false;
}

// ============================================================================
// TODO 3 (parte 2): Análise sintática — pipeline, redirecionamentos e &
// ============================================================================

/// Converte a lista de tokens em um `Pipeline`. As strings dos argumentos
/// apontam para o texto dos tokens (não são copiadas).
fn parse(allocator: Allocator, tokens: []const Token) ParseError!Pipeline {
    var pipeline: Pipeline = .{};
    errdefer pipeline.deinit(allocator);
    if (tokens.len == 0) return pipeline;

    var current = ParsedCommand.init(allocator);
    errdefer current.deinit();

    // Operador de redirecionamento aguardando o nome do arquivo.
    var pending: ?TokenKind = null;

    for (tokens, 0..) |tok, idx| {
        switch (tok.kind) {
            .word => {
                if (pending) |op| {
                    switch (op) {
                        .redirect_in => current.stdin_file = tok.text,
                        .redirect_out => current.stdout_file = tok.text,
                        .redirect_err => current.stderr_file = tok.text,
                        else => unreachable,
                    }
                    pending = null;
                } else {
                    try current.args.append(allocator, tok.text);
                }
            },
            .redirect_in, .redirect_out, .redirect_err => {
                if (pending != null) return error.MissingRedirectTarget;
                pending = tok.kind;
            },
            .pipe => {
                if (pending != null) return error.MissingRedirectTarget;
                if (current.args.items.len == 0) return error.EmptyCommand;
                try pipeline.commands.append(allocator, current);
                current = ParsedCommand.init(allocator);
            },
            .background => {
                if (pending != null) return error.MissingRedirectTarget;
                if (idx != tokens.len - 1) return error.MisplacedBackground;
                pipeline.is_background = true;
            },
        }
    }

    if (pending != null) return error.MissingRedirectTarget;
    if (current.args.items.len == 0) return error.EmptyCommand;
    try pipeline.commands.append(allocator, current);
    current = ParsedCommand.init(allocator); // posse transferida ao pipeline

    for (pipeline.commands.items) |*cmd| cmd.is_background = pipeline.is_background;
    return pipeline;
}

// ============================================================================
// Estado do shell
// ============================================================================

/// Um trabalho em segundo plano (um comando ou um pipeline inteiro).
const Job = struct {
    id: u32,
    children: []Child,
    cmdline: []u8,
    /// Índice em `children` do último estágio do pipeline (null se ele não
    /// pôde ser criado).
    last_child: ?usize,
    /// Código de saída do último estágio (preenchido quando ele termina).
    status: u8 = 0,
};

const Builtin = enum { cd, pwd, help, exit, jobs };

const Shell = struct {
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    last_status: u8 = 0,
    jobs: std.ArrayList(Job) = .empty,
    next_job_id: u32 = 1,
    /// Diretório anterior, usado por `cd -`.
    prev_dir: ?[:0]u8 = null,

    fn deinit(sh: *Shell) void {
        for (sh.jobs.items) |job| {
            sh.gpa.free(job.children);
            sh.gpa.free(job.cmdline);
        }
        sh.jobs.deinit(sh.gpa);
        if (sh.prev_dir) |p| sh.gpa.free(p);
    }

    /// Escreve uma mensagem de erro no stderr do shell.
    fn printErr(sh: *Shell, comptime fmt: []const u8, args: anytype) void {
        sh.out.flush() catch {};
        sh.err.print("zigsh: " ++ fmt ++ "\n", args) catch {};
        sh.err.flush() catch {};
    }

    // ------------------------------------------------------------------------
    // TODO 1: Prompt dinâmico
    // ------------------------------------------------------------------------
    fn printPrompt(sh: *Shell) !void {
        var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd: []const u8 = if (std.process.currentPath(sh.io, &cwd_buf)) |n|
            cwd_buf[0..n]
        else |_|
            "?";

        const prompt = std.fmt.bufPrint(&signal_state.prompt_buf, "zigsh [{s}]> ", .{cwd}) catch
            "zigsh> ";
        signal_state.prompt_len.store(prompt.len, .release);

        try sh.out.writeAll(prompt);
        try sh.out.flush();
        signal_state.at_prompt.store(true, .release);
    }

    // ------------------------------------------------------------------------
    // Processamento de uma linha
    // ------------------------------------------------------------------------
    fn processLine(sh: *Shell, arena: Allocator, raw: []const u8) void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return;

        const tokens = tokenize(arena, line) catch |e| {
            sh.printErr("erro de sintaxe: {s}", .{describeParseError(e)});
            sh.last_status = 2;
            return;
        };
        var pipeline = parse(arena, tokens) catch |e| {
            sh.printErr("erro de sintaxe: {s}", .{describeParseError(e)});
            sh.last_status = 2;
            return;
        };
        defer pipeline.deinit(arena);
        if (pipeline.commands.items.len == 0) return; // linha só com comentário

        sh.runPipeline(&pipeline) catch |e| {
            sh.printErr("erro interno: {s}", .{@errorName(e)});
            sh.last_status = 1;
        };
    }

    fn runPipeline(sh: *Shell, pipeline: *const Pipeline) !void {
        const cmds = pipeline.commands.items;

        // --------------------------------------------------------------------
        // TODO 4: Comandos internos (executados no próprio processo do shell)
        // --------------------------------------------------------------------
        if (cmds.len == 1) {
            if (std.meta.stringToEnum(Builtin, cmds[0].args.items[0])) |b| {
                if (pipeline.is_background) {
                    sh.printErr("{s}: comandos internos são executados em primeiro plano; '&' ignorado", .{@tagName(b)});
                }
                sh.last_status = try sh.runBuiltin(b, &cmds[0]);
                return;
            }
        } else {
            for (cmds) |*cmd| {
                if (std.meta.stringToEnum(Builtin, cmd.args.items[0])) |b| {
                    sh.printErr("{s}: comandos internos não podem ser usados em pipelines", .{@tagName(b)});
                    sh.last_status = 2;
                    return;
                }
            }
        }

        try sh.runExternal(pipeline);
    }

    // ------------------------------------------------------------------------
    // TODO 5, 6, 7 e 8: Comandos externos, redirecionamentos, pipeline e
    // controle de concorrência.
    // ------------------------------------------------------------------------
    fn runExternal(sh: *Shell, pipeline: *const Pipeline) !void {
        const io = sh.io;
        const cmds = pipeline.commands.items;

        // TODO 6: abre TODOS os arquivos de redirecionamento antes de criar
        // qualquer processo. Se algum falhar, nada é executado (como no bash).
        const Redirs = struct { stdin: ?File = null, stdout: ?File = null, stderr: ?File = null };
        const redirs = try sh.gpa.alloc(Redirs, cmds.len);
        defer sh.gpa.free(redirs);
        @memset(redirs, .{});
        // O processo filho recebe a própria cópia do descritor (dup2 no Linux),
        // então o pai pode fechar os arquivos logo após o spawn.
        defer for (redirs) |r| {
            if (r.stdin) |f| f.close(io);
            if (r.stdout) |f| f.close(io);
            if (r.stderr) |f| f.close(io);
        };
        for (cmds, redirs) |*cmd, *r| {
            if (cmd.stdin_file) |path| r.stdin = sh.openInput(path) orelse return;
            if (cmd.stdout_file) |path| r.stdout = sh.createOutput(path) orelse return;
            if (cmd.stderr_file) |path| r.stderr = sh.createOutput(path) orelse return;
        }

        // Garante que tudo que o shell já escreveu apareça antes da saída dos filhos.
        try sh.out.flush();

        var spawned: std.ArrayList(Child) = .empty;
        defer spawned.deinit(sh.gpa);
        try spawned.ensureTotalCapacity(sh.gpa, cmds.len);

        // Extremidade de leitura do pipe criado para o estágio anterior.
        var prev_pipe: ?File = null;
        defer if (prev_pipe) |f| f.close(io);

        // Índice (em `spawned`) do último estágio, se ele foi criado.
        var last_child: ?usize = null;
        // Código de saída quando o último estágio nem chegou a ser criado.
        var last_spawn_status: u8 = 0;
        // No Linux, todos os processos de um job em segundo plano vão para um
        // grupo de processos próprio, para não receberem o Ctrl+C do terminal.
        var bg_pgid: if (is_posix) ?std.posix.pid_t else void = if (is_posix) null else {};

        for (cmds, redirs, 0..) |*cmd, r, i| {
            const is_last = i == cmds.len - 1;

            // TODO 7: conexão via pipe. O stdout do estágio i é criado como
            // `.pipe`; a extremidade de leitura vira o stdin do estágio i+1.
            // Redirecionamentos explícitos têm prioridade sobre o pipe.
            const stdin_opt: StdIo = if (r.stdin) |f|
                .{ .file = f }
            else if (i == 0)
                .inherit
            else if (prev_pipe) |p|
                .{ .file = p }
            else
                .ignore; // estágio anterior não produziu pipe (redirecionado ou falhou)

            const stdout_opt: StdIo = if (r.stdout) |f|
                .{ .file = f }
            else if (!is_last)
                .pipe
            else
                .inherit;

            const stderr_opt: StdIo = if (r.stderr) |f| .{ .file = f } else .inherit;

            // TODO 5: criação do processo filho com std.process.Child.
            const result = std.process.spawn(io, .{
                .argv = cmd.args.items,
                .stdin = stdin_opt,
                .stdout = stdout_opt,
                .stderr = stderr_opt,
                .pgid = if (is_posix and pipeline.is_background) (bg_pgid orelse 0) else null,
            });

            // O filho já tem sua própria cópia da extremidade de leitura; o pai
            // fecha a dele. Se o pai a mantivesse aberta, um escritor cujo
            // leitor terminou cedo (ex.: `yes | head -1`) nunca receberia
            // SIGPIPE e ficaria bloqueado para sempre com o pipe cheio.
            if (prev_pipe) |p| {
                p.close(io);
                prev_pipe = null;
            }

            if (result) |child_value| {
                var child = child_value;
                if (!is_last and r.stdout == null) {
                    prev_pipe = child.stdout;
                    child.stdout = null; // posse transferida para `prev_pipe`
                }
                if (is_posix and pipeline.is_background and bg_pgid == null) bg_pgid = child.id.?;
                spawned.appendAssumeCapacity(child);
                if (is_last) last_child = spawned.items.len - 1;
            } else |e| {
                const status = spawnErrorStatus(e);
                sh.printErr("{s}: {s}", .{ cmd.args.items[0], describeSpawnError(e) });
                if (is_last) last_spawn_status = status;
            }
        }

        // TODO 8: controle de concorrência.
        if (pipeline.is_background) {
            if (spawned.items.len == 0) {
                sh.last_status = last_spawn_status;
                return;
            }
            const cmdline = try formatCmdline(sh.gpa, pipeline);
            errdefer sh.gpa.free(cmdline);
            const children = try spawned.toOwnedSlice(sh.gpa);
            errdefer sh.gpa.free(children);
            const job: Job = .{
                .id = sh.next_job_id,
                .children = children,
                .cmdline = cmdline,
                .last_child = last_child,
                .status = last_spawn_status,
            };
            try sh.jobs.append(sh.gpa, job);
            sh.next_job_id += 1;

            try sh.out.print("[Processo disparado em segundo plano] [{d}]", .{job.id});
            if (is_posix) {
                for (job.children) |child| try sh.out.print(" {d}", .{child.id.?});
            }
            try sh.out.writeAll("\n");
            try sh.out.flush();
            sh.last_status = 0;
        } else {
            // Primeiro plano: aguarda TODOS os processos do pipeline.
            var status: u8 = last_spawn_status;
            for (spawned.items, 0..) |*child, idx| {
                const term = child.wait(io) catch |e| {
                    sh.printErr("erro ao aguardar processo: {s}", .{@errorName(e)});
                    if (last_child == idx) status = 1;
                    continue;
                };
                if (last_child == idx) status = termToStatus(term);
            }
            sh.last_status = status;
        }
    }

    fn openInput(sh: *Shell, path: []const u8) ?File {
        return Io.Dir.cwd().openFile(sh.io, path, .{}) catch |e| {
            sh.printErr("{s}: {s}", .{ path, describeFsError(e) });
            sh.last_status = 1;
            return null;
        };
    }

    fn createOutput(sh: *Shell, path: []const u8) ?File {
        return Io.Dir.cwd().createFile(sh.io, path, .{ .truncate = true }) catch |e| {
            sh.printErr("{s}: {s}", .{ path, describeFsError(e) });
            sh.last_status = 1;
            return null;
        };
    }

    // ------------------------------------------------------------------------
    // Trabalhos em segundo plano: coleta processos que já terminaram
    // (evita processos zumbis) e avisa o usuário.
    // ------------------------------------------------------------------------
    fn reapJobs(sh: *Shell) void {
        var i: usize = 0;
        while (i < sh.jobs.items.len) {
            const job = &sh.jobs.items[i];
            var all_done = true;
            for (job.children, 0..) |*child, idx| {
                if (child.id == null) continue;
                if (pollChild(sh.io, child)) |st| {
                    if (job.last_child == idx) job.status = st;
                } else {
                    all_done = false;
                }
            }
            if (all_done) {
                sh.out.print("[{d}]+ Concluído (código {d})    {s}\n", .{ job.id, job.status, job.cmdline }) catch {};
                sh.gpa.free(job.children);
                sh.gpa.free(job.cmdline);
                _ = sh.jobs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        if (sh.jobs.items.len == 0) sh.next_job_id = 1;
    }

    // ------------------------------------------------------------------------
    // TODO 4: implementação dos comandos internos
    // ------------------------------------------------------------------------
    fn runBuiltin(sh: *Shell, b: Builtin, cmd: *const ParsedCommand) !u8 {
        const io = sh.io;

        // Redirecionamentos também valem para comandos internos (ex.: pwd > f).
        var out_file: ?File = null;
        defer if (out_file) |f| f.close(io);
        var err_file: ?File = null;
        defer if (err_file) |f| f.close(io);
        if (cmd.stdin_file) |path| {
            const f = sh.openInput(path) orelse return 1;
            f.close(io); // nenhum comando interno lê o stdin
        }
        if (cmd.stdout_file) |path| out_file = sh.createOutput(path) orelse return 1;
        if (cmd.stderr_file) |path| err_file = sh.createOutput(path) orelse return 1;

        var out_buf: [1024]u8 = undefined;
        var out_fw: File.Writer = undefined;
        var out: *Io.Writer = sh.out;
        if (out_file) |f| {
            out_fw = f.writerStreaming(io, &out_buf);
            out = &out_fw.interface;
        }
        var err_buf: [1024]u8 = undefined;
        var err_fw: File.Writer = undefined;
        var err: *Io.Writer = sh.err;
        if (err_file) |f| {
            err_fw = f.writerStreaming(io, &err_buf);
            err = &err_fw.interface;
        }
        // Executa antes dos `defer` que fecham os arquivos (ordem LIFO).
        defer {
            out.flush() catch {};
            err.flush() catch {};
        }

        const args = cmd.args.items[1..];
        return switch (b) {
            .cd => sh.builtinCd(args, out, err),
            .pwd => sh.builtinPwd(out, err),
            .help => builtinHelp(out),
            .exit => sh.builtinExit(args, err),
            .jobs => sh.builtinJobs(out),
        };
    }

    fn homeDir(sh: *Shell) ?[]const u8 {
        if (sh.environ_map.get("HOME")) |h| return h;
        if (is_windows) return sh.environ_map.get("USERPROFILE");
        return null;
    }

    /// cd [diretório] — sem argumento (ou `~`) vai para $HOME; `cd -` volta
    /// ao diretório anterior; `~/x` é expandido para $HOME/x.
    fn builtinCd(sh: *Shell, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
        if (args.len > 1) {
            try err.writeAll("zigsh: cd: muitos argumentos\n");
            return 1;
        }

        var expanded: ?[]u8 = null;
        defer if (expanded) |e| sh.gpa.free(e);
        var print_dir = false;

        const target: []const u8 = blk: {
            if (args.len == 0 or std.mem.eql(u8, args[0], "~")) {
                break :blk sh.homeDir() orelse {
                    try err.writeAll("zigsh: cd: HOME não definido\n");
                    return 1;
                };
            }
            if (std.mem.eql(u8, args[0], "-")) {
                print_dir = true;
                break :blk sh.prev_dir orelse {
                    try err.writeAll("zigsh: cd: diretório anterior não definido\n");
                    return 1;
                };
            }
            if (std.mem.startsWith(u8, args[0], "~/")) {
                const home = sh.homeDir() orelse {
                    try err.writeAll("zigsh: cd: HOME não definido\n");
                    return 1;
                };
                expanded = try std.mem.concat(sh.gpa, u8, &.{ home, args[0][1..] });
                break :blk expanded.?;
            }
            break :blk args[0];
        };

        const old_dir = std.process.currentPathAlloc(sh.io, sh.gpa) catch null;
        // Equivalente, no Zig 0.16, ao antigo std.process.changeCurDir().
        std.process.setCurrentPath(sh.io, target) catch |e| {
            if (old_dir) |d| sh.gpa.free(d);
            try err.print("zigsh: cd: {s}: {s}\n", .{ target, describeFsError(e) });
            return 1;
        };

        // `target` pode apontar para `prev_dir` (cd -): só liberamos depois de usá-lo.
        if (print_dir) try printCwd(sh, out);
        if (sh.prev_dir) |p| sh.gpa.free(p);
        sh.prev_dir = old_dir;
        return 0;
    }

    fn builtinPwd(sh: *Shell, out: *Io.Writer, err: *Io.Writer) !u8 {
        printCwd(sh, out) catch |e| switch (e) {
            error.WriteFailed => return e,
            else => {
                try err.print("zigsh: pwd: {s}\n", .{@errorName(e)});
                return 1;
            },
        };
        return 0;
    }

    fn printCwd(sh: *Shell, out: *Io.Writer) !void {
        const cwd = try std.process.currentPathAlloc(sh.io, sh.gpa);
        defer sh.gpa.free(cwd);
        try out.print("{s}\n", .{cwd});
    }

    fn builtinExit(sh: *Shell, args: []const []const u8, err: *Io.Writer) !u8 {
        if (args.len > 1) {
            try err.writeAll("zigsh: exit: muitos argumentos\n");
            return 1;
        }
        var code: u8 = sh.last_status;
        if (args.len == 1) {
            const n = std.fmt.parseInt(i64, args[0], 10) catch {
                try err.print("zigsh: exit: {s}: argumento numérico necessário\n", .{args[0]});
                return 2;
            };
            code = @intCast(@mod(n, 256)); // mesmo comportamento do bash
        }
        sh.out.flush() catch {};
        err.flush() catch {};
        std.process.exit(code);
    }

    fn builtinJobs(sh: *Shell, out: *Io.Writer) !u8 {
        sh.reapJobs();
        for (sh.jobs.items) |job| {
            try out.print("[{d}]  Executando    {s}\n", .{ job.id, job.cmdline });
        }
        return 0;
    }
};

fn builtinHelp(out: *Io.Writer) !u8 {
    try out.writeAll(
        \\zigsh — shell minimalista em Zig
        \\
        \\Comandos internos:
        \\  cd [diretório]   altera o diretório atual (sem argumento: $HOME; '-': anterior)
        \\  pwd              mostra o diretório atual
        \\  help             mostra esta ajuda
        \\  exit [código]    encerra o shell (padrão: código do último comando)
        \\  jobs             lista os processos em segundo plano ainda em execução
        \\
        \\Operadores:
        \\  cmd > arquivo    redireciona a saída padrão (stdout) para o arquivo
        \\  cmd 2> arquivo   redireciona a saída de erros (stderr) para o arquivo
        \\  cmd < arquivo    lê a entrada padrão (stdin) do arquivo
        \\  cmd1 | cmd2      conecta o stdout de cmd1 ao stdin de cmd2 (pipeline)
        \\  cmd &            executa em segundo plano (deve ser o último token)
        \\
        \\Aspas: '...' é literal; "..." aceita \" \\ \n \t. Use Ctrl+D para sair.
        \\
    );
    return 0;
}

/// Reconstrói a linha de comando (para exibição em mensagens de jobs).
fn formatCmdline(gpa: Allocator, pipeline: *const Pipeline) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (pipeline.commands.items, 0..) |cmd, i| {
        if (i > 0) try buf.appendSlice(gpa, " | ");
        for (cmd.args.items, 0..) |arg, j| {
            if (j > 0) try buf.append(gpa, ' ');
            try buf.appendSlice(gpa, arg);
        }
    }
    return buf.toOwnedSlice(gpa);
}

// ============================================================================
// Funções auxiliares de processos
// ============================================================================

/// Converte o término de um processo em um código de saída no estilo do sh
/// (128 + sinal quando o processo é morto por um sinal).
fn termToStatus(term: Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +% @as(u8, @truncate(@intFromEnum(sig))),
        .unknown => 1,
    };
}

/// Verifica, sem bloquear, se um processo em segundo plano já terminou.
/// Retorna o código de saída se terminou, ou null se ainda está rodando.
fn pollChild(io: Io, child: *Child) ?u8 {
    switch (native_os) {
        .linux => {
            const linux = std.os.linux;
            var st: u32 = 0;
            const rc = linux.waitpid(child.id.?, &st, linux.W.NOHANG);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return null; // ainda executando
                    child.id = null;
                    if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
                    if (linux.W.IFSIGNALED(st)) return 128 +% @as(u8, @truncate(@intFromEnum(linux.W.TERMSIG(st))));
                    return 1;
                },
                else => {
                    child.id = null; // ECHILD: já foi coletado
                    return 1;
                },
            }
        },
        .windows => {
            const windows = std.os.windows;
            const zero_timeout: windows.LARGE_INTEGER = 0;
            switch (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &zero_timeout)) {
                windows.NTSTATUS.WAIT_0 => {
                    const term = child.wait(io) catch return 1;
                    return termToStatus(term);
                },
                else => return null,
            }
        },
        else => {
            // Outros sistemas: sem coleta não-bloqueante; o job é mantido na lista.
            return null;
        },
    }
}

fn spawnErrorStatus(err: std.process.SpawnError) u8 {
    return switch (err) {
        error.FileNotFound => 127,
        else => 126,
    };
}

fn describeSpawnError(err: std.process.SpawnError) []const u8 {
    return switch (err) {
        error.FileNotFound => "comando não encontrado",
        error.AccessDenied, error.PermissionDenied => "permissão negada",
        error.IsDir => "é um diretório",
        error.InvalidExe => "formato de executável inválido",
        error.NotDir => "não é um diretório",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "recursos do sistema insuficientes",
        else => @errorName(err),
    };
}

fn describeFsError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "arquivo ou diretório inexistente",
        error.NotDir => "não é um diretório",
        error.IsDir => "é um diretório",
        error.AccessDenied, error.PermissionDenied => "permissão negada",
        error.NameTooLong => "nome muito longo",
        error.BadPathName => "caminho inválido",
        error.SymLinkLoop => "laço de links simbólicos",
        else => @errorName(err),
    };
}

// ============================================================================
// Tratamento de Ctrl+C (Linux)
// ============================================================================
//
// O shell não deve morrer com Ctrl+C. Instalamos um tratador (e não SIG_IGN)
// porque tratadores voltam ao padrão no execve(): assim os filhos em primeiro
// plano continuam sendo interrompidos normalmente pelo Ctrl+C, enquanto o
// shell apenas pula de linha e reexibe o prompt.

const signal_state = struct {
    var at_prompt = std.atomic.Value(bool).init(false);
    var prompt_buf: [Io.Dir.max_path_bytes + 16]u8 = undefined;
    var prompt_len = std.atomic.Value(usize).init(0);
};

fn sigintHandler(_: std.os.linux.SIG) callconv(.c) void {
    const linux = std.os.linux;
    // Somente chamadas async-signal-safe (write) aqui.
    _ = linux.write(1, "\n", 1);
    if (signal_state.at_prompt.load(.acquire)) {
        _ = linux.write(1, &signal_state.prompt_buf, signal_state.prompt_len.load(.acquire));
    }
}

fn installSignalHandlers() void {
    if (native_os != .linux) return;
    const linux = std.os.linux;
    const act: linux.Sigaction = .{
        .handler = .{ .handler = sigintHandler },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(.INT, &act, null);
}

// ============================================================================
// Programa principal — ciclo REPL
// ============================================================================

// Utilização da assinatura idiomática Juicy Main em Zig 0.16.x
pub fn main(init: std.process.Init) !void {
    const code = try run(init);
    std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // Leitura/escrita em modo "streaming": o terminal (ou um arquivo/pipe
    // compartilhado com processos filhos) não deve ser acessado por posição.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = File.stdin().readerStreaming(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = File.stdout().writerStreaming(io, &stdout_buf);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = File.stderr().writerStreaming(io, &stderr_buf);

    var shell: Shell = .{
        .gpa = gpa,
        .io = io,
        .environ_map = init.environ_map,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
    };
    defer shell.deinit();

    installSignalHandlers();

    // Memória temporária de cada linha (tokens, argumentos), liberada a cada volta.
    var line_arena = std.heap.ArenaAllocator.init(gpa);
    defer line_arena.deinit();

    while (true) {
        _ = line_arena.reset(.retain_capacity);
        shell.reapJobs();

        // TODO 1: prompt dinâmico com o diretório atual.
        try shell.printPrompt();

        // TODO 2: leitura da linha até '\n'; EOF (Ctrl+D) encerra o shell.
        const maybe_line = stdin.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                signal_state.at_prompt.store(false, .release);
                _ = stdin.discardDelimiterInclusive('\n') catch {};
                shell.printErr("linha muito longa (máximo de {d} bytes)", .{stdin_buf.len});
                shell.last_status = 2;
                continue;
            },
            error.ReadFailed => {
                signal_state.at_prompt.store(false, .release);
                shell.printErr("erro ao ler a entrada padrão", .{});
                return 1;
            },
        };
        signal_state.at_prompt.store(false, .release);

        const line = maybe_line orelse {
            // Ctrl+D: encerramento gracioso.
            try shell.out.writeAll("\nexit\n");
            try shell.out.flush();
            break;
        };

        // TODO 3 a 8.
        shell.processLine(line_arena.allocator(), line);
    }

    return shell.last_status;
}

// ============================================================================
// Testes unitários (zig build test)
// ============================================================================

const testing = std.testing;

fn expectTokens(line: []const u8, expected: []const Token) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), line);
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |e, t| {
        try testing.expectEqual(e.kind, t.kind);
        try testing.expectEqualStrings(e.text, t.text);
    }
}

fn w(text: []const u8) Token {
    return .{ .kind = .word, .text = text };
}

test "tokenize: palavras separadas por espaço" {
    try expectTokens("  /bin/ls   -l  /tmp ", &.{ w("/bin/ls"), w("-l"), w("/tmp") });
    try expectTokens("", &.{});
    try expectTokens("   \t ", &.{});
}

test "tokenize: operadores com e sem espaços" {
    try expectTokens("a > b 2> c < d | e &", &.{
        w("a"),                     .{ .kind = .redirect_out }, w("b"),
        .{ .kind = .redirect_err }, w("c"),                     .{ .kind = .redirect_in },
        w("d"),                     .{ .kind = .pipe },         w("e"),
        .{ .kind = .background },
    });
    try expectTokens("ls>out 2>err|wc&", &.{
        w("ls"),                    .{ .kind = .redirect_out }, w("out"),
        .{ .kind = .redirect_err }, w("err"),                   .{ .kind = .pipe },
        w("wc"),                    .{ .kind = .background },
    });
}

test "tokenize: 2> só vale no início de uma palavra sem aspas" {
    try expectTokens("echo a2>f", &.{ w("echo"), w("a2"), .{ .kind = .redirect_out }, w("f") });
    try expectTokens("echo \"2\">f", &.{ w("echo"), w("2"), .{ .kind = .redirect_out }, w("f") });
    try expectTokens("echo 2 > f", &.{ w("echo"), w("2"), .{ .kind = .redirect_out }, w("f") });
}

test "tokenize: aspas e escapes" {
    try expectTokens("/bin/echo \"Teste de criacao\" > saida.txt", &.{
        w("/bin/echo"), w("Teste de criacao"), .{ .kind = .redirect_out }, w("saida.txt"),
    });
    try expectTokens("echo \"Linha 1\\nAlvo 123\"", &.{ w("echo"), w("Linha 1\nAlvo 123") });
    try expectTokens("echo 'sem \\n escape' \"a|b\" '>' x\\ y", &.{
        w("echo"), w("sem \\n escape"), w("a|b"), w(">"), w("x y"),
    });
    try expectTokens("echo \"\" ''", &.{ w("echo"), w(""), w("") });
    try expectTokens("echo ab\"cd\"'ef'", &.{ w("echo"), w("abcdef") });
    try expectTokens("echo \"aspas \\\"internas\\\"\"", &.{ w("echo"), w("aspas \"internas\"") });
    try expectTokens("echo a \\", &.{ w("echo"), w("a") });
    try testing.expectError(error.UnterminatedQuote, tokenize(testing.allocator, "echo \"abc"));
    try testing.expectError(error.UnterminatedQuote, tokenize(testing.allocator, "echo 'abc"));
}

test "tokenize: comentários" {
    try expectTokens("# só comentário", &.{});
    try expectTokens("echo a # resto", &.{ w("echo"), w("a") });
    try expectTokens("echo a#b", &.{ w("echo"), w("a#b") });
}

fn parseLine(arena: Allocator, line: []const u8) ParseError!Pipeline {
    return parse(arena, try tokenize(arena, line));
}

test "parse: comando simples com redirecionamentos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseLine(arena.allocator(), "/bin/grep Teste < saida.txt > out.txt 2> err.log");
    try testing.expectEqual(@as(usize, 1), p.commands.items.len);
    const cmd = p.commands.items[0];
    try testing.expectEqual(@as(usize, 2), cmd.args.items.len);
    try testing.expectEqualStrings("/bin/grep", cmd.args.items[0]);
    try testing.expectEqualStrings("Teste", cmd.args.items[1]);
    try testing.expectEqualStrings("saida.txt", cmd.stdin_file.?);
    try testing.expectEqualStrings("out.txt", cmd.stdout_file.?);
    try testing.expectEqualStrings("err.log", cmd.stderr_file.?);
    try testing.expect(!p.is_background);
}

test "parse: background e pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bg = try parseLine(a, "/bin/sleep 5 &");
    try testing.expect(bg.is_background);
    try testing.expect(bg.commands.items[0].is_background);
    try testing.expectEqual(@as(usize, 2), bg.commands.items[0].args.items.len);

    const pl = try parseLine(a, "/bin/cat a.txt | /bin/grep x | /usr/bin/wc -l");
    try testing.expectEqual(@as(usize, 3), pl.commands.items.len);
    try testing.expectEqualStrings("/usr/bin/wc", pl.commands.items[2].args.items[0]);
    try testing.expectEqualStrings("-l", pl.commands.items[2].args.items[1]);

    const empty = try parseLine(a, "   # nada");
    try testing.expectEqual(@as(usize, 0), empty.commands.items.len);
}

test "parse: erros de sintaxe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.EmptyCommand, parseLine(a, "| grep x"));
    try testing.expectError(error.EmptyCommand, parseLine(a, "ls |"));
    try testing.expectError(error.EmptyCommand, parseLine(a, "ls || wc"));
    try testing.expectError(error.EmptyCommand, parseLine(a, "&"));
    try testing.expectError(error.EmptyCommand, parseLine(a, "> arquivo"));
    try testing.expectError(error.MissingRedirectTarget, parseLine(a, "ls >"));
    try testing.expectError(error.MissingRedirectTarget, parseLine(a, "ls > > f"));
    try testing.expectError(error.MissingRedirectTarget, parseLine(a, "ls > | wc"));
    try testing.expectError(error.MisplacedBackground, parseLine(a, "sleep 1 & ls"));
}

test "parse: sem vazamento de memória com o alocador de testes" {
    const tokens = try tokenize(testing.allocator, "a b | c > d &");
    defer {
        for (tokens) |t| if (t.kind == .word) testing.allocator.free(t.text);
        testing.allocator.free(tokens);
    }
    var p = try parse(testing.allocator, tokens);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), p.commands.items.len);

    try testing.expectError(error.MissingRedirectTarget, parse(testing.allocator, tokens[0..5]));
}

test "termToStatus" {
    try testing.expectEqual(@as(u8, 0), termToStatus(.{ .exited = 0 }));
    try testing.expectEqual(@as(u8, 3), termToStatus(.{ .exited = 3 }));
}
