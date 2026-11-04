#!/usr/bin/env bash
# Roteiro de testes automatizado do zigsh (Testes A–F do enunciado + extras).
#
# Uso:
#   zig build && tests/run_tests.sh               # usa ./zig-out/bin/zigsh
#   tests/run_tests.sh caminho/para/zigsh
#
# Variáveis opcionais:
#   BIN=/usr/bin   diretório dos utilitários (padrão: /bin)
#   TMPD=/tmp      diretório usado no Teste A (padrão: /tmp)

set -u

ZIGSH=${1:-./zig-out/bin/zigsh}
B=${BIN:-/bin}
T=${TMPD:-/tmp}

if [ ! -x "$ZIGSH" ]; then
    echo "zigsh não encontrado em '$ZIGSH'. Rode 'zig build' antes." >&2
    exit 2
fi
ZIGSH=$(cd "$(dirname "$ZIGSH")" && pwd)/$(basename "$ZIGSH")

WORK=$(mktemp -d)
OUTF=$(mktemp)
trap 'rm -rf "$WORK" "$OUTF"' EXIT

PASS=0
FAIL=0

# Executa o zigsh dentro de $WORK com a entrada $1 (em printf %b: "\n"
# separa comandos). A saída bruta (stdout+stderr) fica em $RAW, a saída sem
# os prompts em $OUT e o código de saída em $CODE.
# A saída vai para um arquivo (e não para um pipe) para que processos em
# segundo plano que herdam o stdout não atrasem o fim da captura.
run() {
    (cd "$WORK" && printf '%b\n' "$1" | timeout 20 "$ZIGSH" >"$OUTF" 2>&1)
    CODE=$?
    RAW=$(cat "$OUTF")
    # Remove os prompts e a linha "exit" impressa pelo shell ao receber EOF.
    OUT=$(sed -E 's/zigsh \[[^]]*\]> //g' "$OUTF" | sed -e '${/^exit$/d;}')
}

ok() {
    PASS=$((PASS + 1))
    printf '  [OK]   %s\n' "$1"
}

ko() {
    FAIL=$((FAIL + 1))
    printf '  [FALHA] %s\n' "$1"
    printf '         saída obtida:\n%s\n' "$OUT" | sed 's/^/         | /'
}

expect_contains() { # $1 = descrição, $2 = texto esperado
    if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else ko "$1 (esperado: '$2')"; fi
}

expect_line() { # $1 = descrição, $2 = linha exata esperada
    if grep -qxF -- "$2" <<<"$OUT"; then ok "$1"; else ko "$1 (linha esperada: '$2')"; fi
}

expect_not_contains() {
    if grep -qF -- "$2" <<<"$OUT"; then ko "$1 (não deveria conter: '$2')"; else ok "$1"; fi
}

expect_code() { # $1 = descrição, $2 = código esperado
    if [ "$CODE" = "$2" ]; then ok "$1"; else ko "$1 (código esperado $2, obtido $CODE)"; fi
}

echo "== Teste A: comandos internos"
run "pwd\ncd $T\npwd\nhelp\nexit 0\necho NAO_DEVE_APARECER"
expect_line "pwd inicial mostra o diretório de trabalho" "$WORK"
expect_line "cd + pwd mostra $T" "$T"
if grep -qF "zigsh [$T]> " <<<"$RAW"; then ok "prompt reflete o novo diretório"; else ko "prompt reflete o novo diretório"; fi
expect_contains "help lista os comandos internos" "Comandos internos"
expect_not_contains "exit encerra o shell" "NAO_DEVE_APARECER"
expect_code "exit 0 retorna código 0" 0
run "exit 7"
expect_code "exit 7 retorna código 7" 7
run "cd /caminho/que/nao/existe\npwd"
expect_contains "cd para diretório inexistente mostra erro" "cd: /caminho/que/nao/existe"
expect_contains "shell continua após erro do cd" "$WORK"

echo "== Teste B: redirecionamento de saída (>)"
run "$B/echo \"Teste de criacao de arquivo pelo shell zigsh\" > saida.txt\n$B/cat saida.txt"
expect_contains "cat mostra o conteúdo gravado" "Teste de criacao de arquivo pelo shell zigsh"
if [ "$(cat "$WORK/saida.txt" 2>/dev/null)" = "Teste de criacao de arquivo pelo shell zigsh" ]; then
    ok "arquivo saida.txt contém exatamente a linha (sem aspas)"
else
    ko "arquivo saida.txt contém exatamente a linha (sem aspas)"
fi
run "$B/echo curto > saida2.txt\n$B/echo x > saida2.txt"
if [ "$(cat "$WORK/saida2.txt" 2>/dev/null)" = "x" ]; then ok "> trunca o arquivo existente"; else ko "> trunca o arquivo existente"; fi

echo "== Teste C: redirecionamento de erro (2>)"
run "$B/ls /caminho_inexistente 2> erros.log"
expect_not_contains "erro não aparece no terminal" "caminho_inexistente"
run "$B/cat erros.log"
expect_contains "erros.log contém a mensagem de erro do ls" "caminho_inexistente"

echo "== Teste D: redirecionamento de entrada (<)"
run "$B/grep \"Teste\" < saida.txt"
expect_contains "grep lê o arquivo pelo stdin" "Teste de criacao de arquivo pelo shell zigsh"
run "$B/cat < nao_existe.txt"
expect_contains "arquivo de entrada inexistente gera erro" "nao_existe.txt"

echo "== Teste E: segundo plano (&)"
START=$(date +%s)
run "$B/sleep 5 &\npwd"
END=$(date +%s)
expect_contains "mensagem de disparo em segundo plano" "[Processo disparado em segundo plano]"
expect_contains "pwd executa sem esperar o sleep" "$WORK"
if [ $((END - START)) -lt 4 ]; then ok "shell não bloqueou esperando o sleep 5"; else ko "shell não bloqueou esperando o sleep 5"; fi
OUT=$(cd "$WORK" && { echo "$B/sleep 1 &"; sleep 3; echo "$B/echo depois"; } | timeout 20 "$ZIGSH" 2>&1 | sed -E 's/zigsh \[[^]]*\]> //g')
expect_contains "job concluído é coletado e anunciado" "Concluído"

echo "== Teste F: pipeline (|)"
run "$B/echo \"Linha 1\\\\nLinha 2\\\\nAlvo 123\" | $B/grep \"Alvo\""
if [ "$OUT" = "Alvo 123" ]; then ok "saída é exatamente 'Alvo 123'"; else ko "saída é exatamente 'Alvo 123'"; fi
run "$B/echo \"c\\\\nb\\\\na\\\\nAlvo\" | $B/grep -v Alvo | sort"
if [ "$OUT" = "$(printf 'a\nb\nc')" ]; then ok "pipeline com 3 estágios"; else ko "pipeline com 3 estágios"; fi
run "$B/cat < saida.txt | tr a-z A-Z > upper.txt\n$B/cat upper.txt"
expect_contains "pipeline com < no início e > no fim" "TESTE DE CRIACAO"
START=$(date +%s)
run "yes | head -n 1"
END=$(date +%s)
if [ "$OUT" = "y" ] && [ $((END - START)) -lt 5 ]; then
    ok "yes | head termina (pai fecha as pontas do pipe)"
else
    ko "yes | head termina (pai fecha as pontas do pipe)"
fi

echo "== Extras: erros e sintaxe"
run "comando_inexistente_xyz\nexit"
expect_contains "comando inexistente" "comando não encontrado"
expect_code "código 127 para comando inexistente" 127
run "$B/ls |"
expect_contains "pipe sem comando é erro de sintaxe" "erro de sintaxe"
run "$B/echo \"abc"
expect_contains "aspas não fechadas" "aspas não fechadas"
run "$B/sleep 1 & $B/ls"
expect_contains "& fora do final é erro de sintaxe" "'&' só é permitido no final"
run "pwd > p.txt\n$B/cat p.txt"
expect_contains "redirecionamento em comando interno" "$WORK"
run "$B/echo 'aspas simples \\\\n literais'"
expect_contains "aspas simples são literais" 'aspas simples \n literais'

echo
echo "Resultado: $PASS OK, $FAIL falha(s)"
[ "$FAIL" -eq 0 ]
