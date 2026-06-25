## Jira
<!-- 연관 이슈 키. PR 제목에도 넣으면 Jira에 자동 링크됨. 스마트커밋: SCRUM-00 #done -->
SCRUM-

## 변경 요약
<!-- 무엇을, 왜 바꿨는지 1~3줄로 -->

## 변경 유형
- [ ] feat (기능/리소스 추가)
- [ ] fix (버그 수정)
- [ ] docs (문서)
- [ ] chore (설정/기타)
- [ ] hotfix (긴급 수정)
- [ ] release (릴리스)

## Terraform plan 결과
<!-- plan 출력 요약 또는 스크린샷. 의도하지 않은 리소스 삭제/교체가 없는지 확인 -->
```
# terraform plan 결과 붙여넣기
```

## 체크리스트
- [ ] `terraform fmt -recursive` 적용
- [ ] `terraform validate` 통과
- [ ] plan 결과 확인 (예상치 못한 `destroy`/`replace` 없음)
- [ ] 관련 문서/README 업데이트
- [ ] 민감정보(키, 시크릿, tfvars)를 커밋하지 않음
