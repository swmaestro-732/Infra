"""Claude 가 고친 .ai 작업 트리를 push 전에 기계적으로 검사한다(SCRUM-639, Infra, 원본 SCRUM-588).

- 자동 반영 허용 경로 밖(에이전트 지시문, 스킬, 결정 기록 등)을 바꿨으면 실패
- 대량 삭제(문서당 30줄, 전체 100줄 초과)면 실패
- 추가된 줄에 토큰처럼 보이는 문자열이 있으면 실패
- Claude 단계 중 .ai/.git/config 가 바뀌었거나 훅이 생겼으면 실패
- 갱신 후보 문서(targets.txt)가 Claude 요약(summary.md)에 하나라도 빠졌으면 실패
- auto 후보의 판정과 실제 변경이 어긋나면 실패("고침"인데 안 바뀜, 바뀌었는데 "고침"이 아님)
- 가운뎃점, em 대시, 커밋 해시 도장은 경고만 남긴다
결과는 GITHUB_STEP_SUMMARY 에도 쓴다. 이 스크립트는 Infra 저장소 파일이라 Claude 단계가 고칠 수 없다.

`check.py targets` 는 Claude 단계 전에 실행해, 바뀐 파일(changed.txt)을 mapping.tsv 와 대조해 갱신 후보
문서 목록(targets.txt)을 만든다. 매핑 판정을 모델에 맡기지 않기 위해서다.
"""

import fnmatch
import os
import re
import subprocess
import sys

WIKI = ".ai"
INPUT = ".wiki-sync-input"
MAPPING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mapping.tsv")
ALLOWED = ("infra/", "runbooks/")
MAX_DELETED_PER_FILE = 30
MAX_DELETED_TOTAL = 100
SECRET = re.compile(r"sk-ant-|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|x-access-token|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY")
HASH_STAMP = re.compile(r"`[0-9a-f]{7,8}`")
UNMAPPED = "(unmapped)"
# 판정 뒤에 괄호 이유 하나로 끝나야 판정으로 인정한다(이유 없는 "갱신 불필요", 괄호 뒤 덧붙임 금지). 이유 안에는 괄호를 쓰지 않는다.
DECISION = re.compile(r"^\s*-\s*`?([^\s`:]+)`?\s*:\s*(고침|갱신 불필요|사람 확인 필요)\s+\([^()\r\n]+\)\s*$")


# 훅과 fsmonitor 를 끄고 git 을 실행한다(설정이 오염됐어도 검사 중 임의 명령이 돌지 않게).
SAFE_GIT = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", WIKI]


def write_summary(text: str) -> None:
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def build_targets() -> int:
    """changed.txt 의 파일을 mapping.tsv 와 대조해 targets.txt(문서<TAB>auto|human<TAB>근거 파일)를 만든다."""
    rules = []
    with open(MAPPING, encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                pattern, doc = line.rstrip("\n").split("\t")
                rules.append((pattern, doc))
    with open(os.path.join(INPUT, "changed.txt"), encoding="utf-8") as f:
        changed = [line.strip() for line in f if line.strip()]
    hits: dict[str, list[str]] = {}
    for path in changed:
        matched = False
        for pattern, doc in rules:
            if fnmatch.fnmatch(path, pattern):
                hits.setdefault(doc, []).append(path)
                matched = True
        # 매핑에 안 걸린 인프라 코드 변경도 판정을 받게 한다(새 모듈, 리소스 등이 조용히 빠지지 않게).
        if not matched and path.startswith("terraform/"):
            hits.setdefault(UNMAPPED, []).append(path)
    rows = []
    for doc in sorted(hits):
        mode = "auto" if doc.startswith(ALLOWED) else "human"  # UNMAPPED 도 human
        files = sorted(set(hits[doc]))
        rows.append(f"{doc}\t{mode}\t{', '.join(files[:5])}{' 외' if len(files) > 5 else ''}")
    with open(os.path.join(INPUT, "targets.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    report = ["## 갱신 후보 문서 (mapping.tsv)", ""]
    report += [f"- `{r.split(chr(9))[0]}` ({r.split(chr(9))[1]})" for r in rows] or ["- 없음"]
    write_summary("\n".join(report) + "\n\n")
    return 0


def read_targets() -> list[tuple[str, str]]:
    path = os.path.join(INPUT, "targets.txt")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [tuple(line.split("\t")[:2]) for line in f if line.strip()]


def read_decisions() -> dict[str, str]:
    """summary.md 에서 "- <문서>: <판정>" 줄만 판정으로 읽는다(부분 문자열 비교는 거짓 통과)."""
    path = os.path.join(INPUT, "summary.md")
    summary = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    decisions = {}
    for line in summary.splitlines():
        m = DECISION.match(line)
        if m:
            decisions[m.group(1)] = m.group(2)
    return decisions


def decision_errors(targets: list[tuple[str, str]], decisions: dict[str, str], changed: set[str]) -> list[str]:
    """모든 후보에 판정이 있고, auto 후보는 "고침" 판정과 실제 변경이 일치해야 한다."""
    if not os.path.exists(os.path.join(INPUT, "targets.txt")):
        return ["targets.txt 가 없음"]
    errors = []
    missing = [doc for doc, _ in targets if doc not in decisions]
    if missing:
        errors.append("요약에 판정이 빠진 갱신 후보 문서: " + ", ".join(missing))
    for doc, mode in targets:
        if mode != "auto" or doc not in decisions:
            continue
        if decisions[doc] == "고침" and doc not in changed:
            errors.append(f"{doc}: 요약은 '고침'인데 실제로 바뀌지 않음")
        if decisions[doc] != "고침" and doc in changed:
            errors.append(f"{doc}: 실제로 바뀌었는데 요약 판정이 '{decisions[doc]}'")
    return errors


def git(*args: str) -> str:
    return subprocess.run([*SAFE_GIT, *args], check=True, capture_output=True, text=True).stdout


def git_metadata_errors() -> list[str]:
    """Claude 단계 전에 저장한 .git/config 해시와 비교하고, 훅 폴더에 샘플 외 파일이 없는지 본다."""
    errors = []
    baseline = os.path.join(".wiki-sync-input", "git-config.sha256")
    if os.path.exists(baseline):
        if subprocess.run(["sha256sum", "--check", "--status", baseline]).returncode != 0:
            errors.append(".ai/.git/config 가 Claude 단계 중에 바뀜")
    else:
        errors.append(".ai/.git/config 기준 해시가 없음")
    hooks = os.path.join(WIKI, ".git", "hooks")
    extra = [f for f in os.listdir(hooks) if not f.endswith(".sample")] if os.path.isdir(hooks) else []
    if extra:
        errors.append(".ai/.git/hooks 에 샘플 외 파일: " + ", ".join(extra))
    return errors


def main() -> int:
    meta_errors = git_metadata_errors()
    if meta_errors:  # 설정이 오염됐으면 git 명령 자체를 더 돌리지 않는다
        print("\n".join(["## 위키 변경 검사", "", "### 실패", *[f"- {e}" for e in meta_errors]]))
        return 1
    git("add", "-A", "--intent-to-add")  # 새 파일도 diff 에 잡히게 한다(내용은 스테이징하지 않음)
    changed = [line for line in git("diff", "--name-only").splitlines() if line]
    targets = read_targets()
    errors, warnings = decision_errors(targets, read_decisions(), set(changed)), []
    target_docs = {doc for doc, _ in targets}
    extra = [p for p in changed if p not in target_docs]
    if extra:  # 허용 범위 안이면 정당한 추가 수정일 수 있어 경고만
        warnings.append("갱신 후보 밖에서 고친 문서: " + ", ".join(extra))

    outside = [p for p in changed if not p.startswith(ALLOWED)]
    if outside:
        errors.append("자동 반영 허용 경로 밖 변경: " + ", ".join(outside))

    total_deleted = 0
    for line in git("diff", "--numstat").splitlines():
        added, deleted, path = line.split("\t", 2)
        deleted_n = int(deleted) if deleted.isdigit() else 0
        total_deleted += deleted_n
        if deleted_n > MAX_DELETED_PER_FILE:
            errors.append(f"{path}: {deleted_n}줄 삭제(문서당 상한 {MAX_DELETED_PER_FILE})")
    if total_deleted > MAX_DELETED_TOTAL:
        errors.append(f"전체 {total_deleted}줄 삭제(상한 {MAX_DELETED_TOTAL})")

    for line in git("diff", "-U0").splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        text = line[1:]
        if SECRET.search(text):
            errors.append("추가된 줄에 토큰처럼 보이는 문자열이 있음")
        if "·" in text or "—" in text:
            warnings.append(f"가운뎃점/em 대시: {text[:80]}")
        if HASH_STAMP.search(text):
            warnings.append(f"커밋 해시 표기: {text[:80]}")

    report = ["## 위키 변경 검사", "", f"바뀐 파일 {len(changed)}개, 삭제 {total_deleted}줄", ""]
    report += [f"- {p}" for p in changed]
    if errors:
        report += ["", "### 실패", *[f"- {e}" for e in sorted(set(errors))]]
    if warnings:
        report += ["", "### 경고", *[f"- {w}" for w in warnings[:20]]]
    write_summary("\n".join(report) + "\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(build_targets() if sys.argv[1:] == ["targets"] else main())
