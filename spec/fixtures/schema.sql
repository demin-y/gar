-- GAR Database Schema for Testing

CREATE SCHEMA IF NOT EXISTS gar;
SET search_path TO gar;

-- Address Object Types
CREATE TABLE IF NOT EXISTS address_object_types (
  id INTEGER PRIMARY KEY,
  level INTEGER NOT NULL,
  short_name VARCHAR(50),
  name VARCHAR(250) NOT NULL,
  "desc" VARCHAR(250),
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_active BOOLEAN DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_address_object_types_level ON address_object_types(level);
CREATE INDEX IF NOT EXISTS idx_address_object_types_name ON address_object_types(name);

-- House Types
CREATE TABLE IF NOT EXISTS house_types (
  id INTEGER PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  short_name VARCHAR(20),
  "desc" VARCHAR(250),
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_active BOOLEAN DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_house_types_name ON house_types(name);

-- Address Objects
CREATE TABLE IF NOT EXISTS address_objects (
  id BIGINT PRIMARY KEY,
  object_id BIGINT NOT NULL,
  object_guid VARCHAR(36),
  change_id BIGINT,
  name VARCHAR(250),
  type_name VARCHAR(50),
  level INTEGER,
  oper_type_id INTEGER,
  prev_id BIGINT,
  next_id BIGINT,
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_actual BOOLEAN DEFAULT true,
  is_active BOOLEAN DEFAULT true,
  full_adm_path TEXT,
  full_mun_path TEXT,
  full_adm_path_tsv TSVECTOR,
  full_mun_path_tsv TSVECTOR
);

CREATE INDEX IF NOT EXISTS idx_address_objects_object_id ON address_objects(object_id);
CREATE INDEX IF NOT EXISTS idx_address_objects_name ON address_objects(name);
CREATE INDEX IF NOT EXISTS idx_address_objects_level ON address_objects(level);
CREATE INDEX IF NOT EXISTS idx_address_objects_type_name ON address_objects(type_name);
CREATE INDEX IF NOT EXISTS idx_address_objects_fulltext ON address_objects USING gin(to_tsvector('russian', name || ' ' || type_name)) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_address_objects_level_is_active ON address_objects(level, is_active);
CREATE INDEX IF NOT EXISTS idx_address_objects_full_adm_path_tsv ON address_objects USING gin(full_adm_path_tsv) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_address_objects_full_mun_path_tsv ON address_objects USING gin(full_mun_path_tsv) WHERE is_active = true;

-- Houses
CREATE TABLE IF NOT EXISTS houses (
  id BIGINT PRIMARY KEY,
  object_id BIGINT NOT NULL,
  object_guid VARCHAR(36),
  change_id BIGINT,
  house_num VARCHAR(50),
  house_type INTEGER,
  oper_type_id INTEGER,
  prev_id BIGINT,
  next_id BIGINT,
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_actual BOOLEAN DEFAULT true,
  is_active BOOLEAN DEFAULT true,
  full_adm_path TEXT,
  full_mun_path TEXT,
  full_adm_path_tsv TSVECTOR,
  full_mun_path_tsv TSVECTOR
);

CREATE INDEX IF NOT EXISTS idx_houses_object_id ON houses(object_id);
CREATE INDEX IF NOT EXISTS idx_houses_house_num ON houses(house_num);
CREATE INDEX IF NOT EXISTS idx_houses_fulltext ON houses USING gin(to_tsvector('russian', house_num)) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_houses_full_adm_path_tsv ON houses USING gin(full_adm_path_tsv) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_houses_full_mun_path_tsv ON houses USING gin(full_mun_path_tsv) WHERE is_active = true;

-- Administrative Hierarchy
CREATE TABLE IF NOT EXISTS adm_hierarchy (
  id BIGINT PRIMARY KEY,
  object_id BIGINT NOT NULL,
  parent_obj_id BIGINT,
  change_id BIGINT,
  region_code VARCHAR(4),
  area_code VARCHAR(4),
  city_code VARCHAR(4),
  place_code VARCHAR(4),
  plan_code VARCHAR(4),
  street_code VARCHAR(4),
  prev_id BIGINT,
  next_id BIGINT,
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_active BOOLEAN DEFAULT true,
  path TEXT
);

CREATE INDEX IF NOT EXISTS idx_adm_hierarchy_object_id ON adm_hierarchy(object_id);
CREATE INDEX IF NOT EXISTS idx_adm_hierarchy_parent_obj_id ON adm_hierarchy(parent_obj_id);

-- Municipal Hierarchy
CREATE TABLE IF NOT EXISTS mun_hierarchy (
  id BIGINT PRIMARY KEY,
  object_id BIGINT NOT NULL,
  parent_obj_id BIGINT,
  change_id BIGINT,
  region_code VARCHAR(4),
  area_code VARCHAR(4),
  city_code VARCHAR(4),
  place_code VARCHAR(4),
  plan_code VARCHAR(4),
  street_code VARCHAR(4),
  prev_id BIGINT,
  next_id BIGINT,
  update_date DATE,
  start_date DATE,
  end_date DATE,
  is_active BOOLEAN DEFAULT true,
  path TEXT
);

CREATE INDEX IF NOT EXISTS idx_mun_hierarchy_object_id ON mun_hierarchy(object_id);
CREATE INDEX IF NOT EXISTS idx_mun_hierarchy_parent_obj_id ON mun_hierarchy(parent_obj_id);
