-- data/operator/bootstrap.sql — 앱 스키마의 권한과 두 계정을 만드는 초기화 SQL (데이터베이스 초기화)
-- 여러 번 실행해도 결과가 같습니다 (WHERE NOT EXISTS · IF NOT EXISTS · GRANT 는 멱등). 비밀번호는 여기에 없습니다 — bootstrap.sh 가 ALTER ROLE 로 따로 넣습니다.
-- :migration_role · :runtime_role · :schema_name · :database_name 은 psql 변수로 전달합니다.
-- 스키마 이름은 계약의 DATA_DB_SCHEMA 이고 값은 public 입니다 — Medusa 2.21 은 연결마다 search_path 를 databaseSchema(기본 public)로 직접 지정하므로
-- 계정의 기본 search_path 로는 다른 스키마로 돌릴 수 없습니다. 그래서 스키마를 따로 만들지 않고 public 안에서 두 계정의 권한을 가릅니다.

\set ON_ERROR_STOP on

-- 1. 스키마 변경 계정과 실행 계정을 만듭니다. 둘 다 로그인만 할 수 있고 상위 권한(SUPERUSER · CREATEDB)은 없습니다.
--    psql 은 $$ … $$ 같은 인용 문자열 안의 :'변수' 를 치환하지 않으므로 DO 블록을 쓰지 않습니다. 바깥 SELECT 가 문장을 만들고 \gexec 가 그 결과를 실행합니다.
SELECT format('CREATE ROLE %I LOGIN', :'migration_role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migration_role')
\gexec
SELECT format('CREATE ROLE %I LOGIN', :'runtime_role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'runtime_role')
\gexec

-- 2. 앱 스키마가 없으면 만듭니다. public 은 이미 있으므로 그대로 두고(소유자도 바뀌지 않습니다) 아래에서 권한만 줍니다.
CREATE SCHEMA IF NOT EXISTS :"schema_name";

-- 3. 아무나 새 객체를 만들지 못하게 합니다 (PostgreSQL 15 부터 public 의 기본값이지만 명시해 둡니다).
REVOKE CREATE ON SCHEMA :"schema_name" FROM PUBLIC;

-- 4. 스키마 변경 계정만 이 스키마에 객체를 만들 수 있습니다 (Medusa 의 db:migrate 가 표 · 색인 · 링크 표를 만듭니다).
GRANT USAGE, CREATE ON SCHEMA :"schema_name" TO :"migration_role";

-- 5. 실행 계정에 필요한 만큼만 줍니다: 스키마 사용 + 표의 행 조작. CREATE 권한은 주지 않습니다.
GRANT USAGE ON SCHEMA :"schema_name" TO :"runtime_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"schema_name" TO :"runtime_role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"runtime_role";

-- 6. 앞으로 스키마 변경 계정이 만드는 표에도 같은 권한이 자동으로 붙게 합니다 (마이그레이션마다 GRANT 를 다시 적지 않기 위함).
--    다른 계정의 기본 권한을 바꾸려면 그 계정의 구성원이어야 합니다. RDS 의 관리자 계정은 SUPERUSER 가 아니므로 먼저 구성원이 됩니다(계정을 만든 쪽이라 ADMIN 권한이 있어 가능).
GRANT :"migration_role" TO CURRENT_USER;
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role" IN SCHEMA :"schema_name"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migration_role" IN SCHEMA :"schema_name"
  GRANT USAGE, SELECT ON SEQUENCES TO :"runtime_role";

-- 7. 두 계정의 기본 검색 경로를 앱 스키마로 맞춥니다 (psql 로 직접 붙어 확인할 때도 같은 자리를 보게 합니다).
ALTER ROLE :"migration_role" IN DATABASE :"database_name" SET search_path = :"schema_name";
ALTER ROLE :"runtime_role" IN DATABASE :"database_name" SET search_path = :"schema_name";
