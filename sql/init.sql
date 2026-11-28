CREATE DATABASE IF NOT EXISTS hrms_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE hrms_db;

-- 1. 部门表
CREATE TABLE IF NOT EXISTS hr_department (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    parent_id BIGINT NOT NULL DEFAULT 0 COMMENT '父部门ID，0表示顶级部门',
    dept_name VARCHAR(64) NOT NULL COMMENT '部门名称',
    leader_name VARCHAR(64) DEFAULT NULL COMMENT '部门负责人姓名',
    headcount_limit INT NOT NULL DEFAULT 20 COMMENT '编制人数',
    description VARCHAR(255) DEFAULT NULL COMMENT '部门描述',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_parent_id (parent_id)
) ENGINE=InnoDB COMMENT='组织部门表';

-- 2. 岗位表
CREATE TABLE IF NOT EXISTS hr_position (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    pos_code VARCHAR(32) NOT NULL UNIQUE COMMENT '岗位编码',
    pos_name VARCHAR(64) NOT NULL COMMENT '岗位名称',
    dept_id BIGINT NOT NULL COMMENT '所属部门ID',
    level_range VARCHAR(32) DEFAULT 'P5-P7' COMMENT '职级范围',
    min_salary DECIMAL(10, 2) NOT NULL DEFAULT 6000.00,
    max_salary DECIMAL(10, 2) NOT NULL DEFAULT 20000.00,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_pos_dept (dept_id)
) ENGINE=InnoDB COMMENT='岗位职级表';

-- 3. 员工档案主表
CREATE TABLE IF NOT EXISTS hr_employee (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    emp_no VARCHAR(32) NOT NULL UNIQUE COMMENT '工号',
    name VARCHAR(64) NOT NULL COMMENT '姓名',
    gender TINYINT NOT NULL DEFAULT 1 COMMENT '1男 2女',
    phone VARCHAR(20) NOT NULL COMMENT '手机号',
    email VARCHAR(100) DEFAULT NULL COMMENT '邮箱',
    id_card VARCHAR(32) DEFAULT NULL COMMENT '身份证号（脱敏展示）',
    dept_id BIGINT NOT NULL COMMENT '部门ID',
    position_id BIGINT DEFAULT NULL COMMENT '岗位ID',
    position_name VARCHAR(64) NOT NULL COMMENT '岗位名称冗余',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '月基本薪资',
    annual_leave_balance DECIMAL(4, 1) NOT NULL DEFAULT 5.0 COMMENT '剩余年假天数',
    hire_date DATE NOT NULL COMMENT '入职日期',
    probation_end_date DATE DEFAULT NULL COMMENT '预计转正日期',
    contract_end_date DATE DEFAULT NULL COMMENT '合同到期日期',
    resign_date DATE DEFAULT NULL COMMENT '离职日期',
    resign_reason VARCHAR(255) DEFAULT NULL COMMENT '离职原因',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'PROBATION/ACTIVE/RESIGNED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_emp_dept (dept_id),
    INDEX idx_emp_status (status),
    INDEX idx_contract_end (contract_end_date)
) ENGINE=InnoDB COMMENT='员工档案表';

-- 4. 员工异动记录表（转正/调岗/调薪）
CREATE TABLE IF NOT EXISTS hr_emp_transfer (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    transfer_type VARCHAR(20) NOT NULL COMMENT 'REGULARIZE/TRANSFER/SALARY_ADJUST/RESIGN',
    before_dept_id BIGINT DEFAULT NULL,
    after_dept_id BIGINT DEFAULT NULL,
    before_position VARCHAR(64) DEFAULT NULL,
    after_position VARCHAR(64) DEFAULT NULL,
    before_salary DECIMAL(10, 2) DEFAULT NULL,
    after_salary DECIMAL(10, 2) DEFAULT NULL,
    effective_date DATE NOT NULL COMMENT '生效日期',
    remark VARCHAR(255) DEFAULT NULL,
    operator_id BIGINT DEFAULT NULL COMMENT '操作人用户ID',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_transfer_emp (employee_id)
) ENGINE=InnoDB COMMENT='员工异动历史表';

-- 5. 系统用户表
CREATE TABLE IF NOT EXISTS sys_user (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(64) NOT NULL UNIQUE COMMENT '登录账号',
    password_hash VARCHAR(128) NOT NULL COMMENT '加盐SHA256哈希',
    role VARCHAR(20) NOT NULL DEFAULT 'EMPLOYEE' COMMENT 'ADMIN/HR/MANAGER/EMPLOYEE',
    employee_id BIGINT DEFAULT NULL COMMENT '关联员工ID',
    is_active TINYINT(1) NOT NULL DEFAULT 1 COMMENT '1启用 0禁用',
    last_login_at DATETIME DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_emp (employee_id)
) ENGINE=InnoDB COMMENT='系统用户表';

-- 6. 考勤打卡记录表
CREATE TABLE IF NOT EXISTS hr_attendance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    work_date DATE NOT NULL COMMENT '考勤日期',
    clock_in_time DATETIME DEFAULT NULL COMMENT '上班打卡时间',
    clock_out_time DATETIME DEFAULT NULL COMMENT '下班打卡时间',
    late_minutes INT NOT NULL DEFAULT 0 COMMENT '迟到分钟数',
    early_minutes INT NOT NULL DEFAULT 0 COMMENT '早退分钟数',
    status VARCHAR(24) NOT NULL DEFAULT 'NORMAL' COMMENT 'NORMAL/LATE/EARLY_LEAVE/LATE_AND_EARLY/ABSENT',
    remark VARCHAR(255) DEFAULT NULL COMMENT '异常说明或补卡备注',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_date (employee_id, work_date),
    INDEX idx_att_date (work_date)
) ENGINE=InnoDB COMMENT='考勤打卡表';

-- 7. 请假与加班申请表
CREATE TABLE IF NOT EXISTS hr_leave_overtime (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '申请人ID',
    category VARCHAR(20) NOT NULL DEFAULT 'LEAVE' COMMENT 'LEAVE请假 / OVERTIME加班',
    sub_type VARCHAR(20) NOT NULL COMMENT 'ANNUAL/SICK/PERSONAL/MARRIAGE/WORKDAY_OT/WEEKEND_OT',
    start_time DATETIME NOT NULL COMMENT '开始时间',
    end_time DATETIME NOT NULL COMMENT '结束时间',
    duration DECIMAL(5, 1) NOT NULL COMMENT '时长（请假为天，加班为小时）',
    reason VARCHAR(500) NOT NULL COMMENT '事由',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING/APPROVED/REJECTED/CANCELLED',
    approver_id BIGINT DEFAULT NULL COMMENT '审批人用户ID',
    approve_remark VARCHAR(255) DEFAULT NULL COMMENT '审批意见',
    approved_at DATETIME DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_lo_emp_status (employee_id, status),
    INDEX idx_lo_category (category)
) ENGINE=InnoDB COMMENT='请假与加班审批表';

-- 8. 绩效考核表
CREATE TABLE IF NOT EXISTS hr_performance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    cycle_name VARCHAR(32) NOT NULL COMMENT '考核周期，如 2026-Q4',
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    self_summary VARCHAR(1000) DEFAULT NULL COMMENT '员工自评总结',
    self_score DECIMAL(5, 1) DEFAULT NULL COMMENT '员工自评分',
    final_score DECIMAL(5, 1) DEFAULT NULL COMMENT '最终得分',
    grade VARCHAR(8) DEFAULT NULL COMMENT 'S/A/B/C/D',
    bonus_ratio DECIMAL(4, 2) NOT NULL DEFAULT 1.00 COMMENT '绩效系数',
    reviewer_id BIGINT DEFAULT NULL COMMENT '评审人用户ID',
    reviewer_comment VARCHAR(500) DEFAULT NULL COMMENT '评审评语',
    status VARCHAR(20) NOT NULL DEFAULT 'SELF_EVAL' COMMENT 'SELF_EVAL/REVIEWING/COMPLETED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_cycle_emp (cycle_name, employee_id)
) ENGINE=InnoDB COMMENT='绩效考核表';

-- 9. 月度薪资表
CREATE TABLE IF NOT EXISTS hr_payroll (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    pay_month VARCHAR(7) NOT NULL COMMENT '发薪月份 YYYY-MM',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    bonus DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '绩效及津贴奖金',
    overtime_pay DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '加班补贴',
    attendance_deduction DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '考勤及事假扣款',
    social_security DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '五险一金个人部分',
    tax DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '个人所得税',
    net_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实发工资',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/PAID',
    paid_at DATETIME DEFAULT NULL,
    remark VARCHAR(255) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_month (employee_id, pay_month)
) ENGINE=InnoDB COMMENT='月度薪资核算表';

-- 10. 招聘候选人表
CREATE TABLE IF NOT EXISTS hr_recruitment_candidate (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(64) NOT NULL COMMENT '候选人姓名',
    gender TINYINT NOT NULL DEFAULT 1,
    phone VARCHAR(20) NOT NULL,
    email VARCHAR(100) DEFAULT NULL,
    target_dept_id BIGINT NOT NULL COMMENT '目标部门ID',
    target_position VARCHAR(64) NOT NULL COMMENT '应聘岗位',
    expected_salary DECIMAL(10, 2) DEFAULT 10000.00,
    source VARCHAR(32) DEFAULT 'BOSS直聘' COMMENT '简历来源',
    stage VARCHAR(20) NOT NULL DEFAULT 'NEW' COMMENT 'NEW/INTERVIEW/OFFER/HIRED/REJECTED',
    interview_notes VARCHAR(500) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_cand_stage (stage)
) ENGINE=InnoDB COMMENT='招聘候选人表';

-- 11. 系统审计日志表
CREATE TABLE IF NOT EXISTS sys_audit_log (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT DEFAULT NULL,
    username VARCHAR(64) DEFAULT NULL,
    module VARCHAR(32) NOT NULL COMMENT '操作模块',
    action VARCHAR(64) NOT NULL COMMENT '操作动作',
    detail VARCHAR(500) DEFAULT NULL COMMENT '操作详情',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_time (created_at)
) ENGINE=InnoDB COMMENT='操作审计日志表';

-- 12. 站内消息通知表
-- 审批通过/驳回、工资条发放等关键事件会给相关账号写一条通知，
-- 前端顶栏铃铛拉取未读数与消息列表。
CREATE TABLE IF NOT EXISTS sys_notification (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT NOT NULL COMMENT '接收人 sys_user.id',
    title VARCHAR(128) NOT NULL COMMENT '消息标题',
    content VARCHAR(500) NOT NULL DEFAULT '' COMMENT '消息正文',
    biz_type VARCHAR(32) NOT NULL DEFAULT 'SYSTEM' COMMENT 'SYSTEM/APPROVAL/PAYROLL/CONTRACT',
    is_read TINYINT NOT NULL DEFAULT 0 COMMENT '0未读 1已读',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_notify_user (user_id, is_read, created_at)
) ENGINE=InnoDB COMMENT='站内消息通知表';

-- ==========================================
-- 初始演示数据（Seed Data）
-- ==========================================
INSERT IGNORE INTO hr_department (id, parent_id, dept_name, leader_name, headcount_limit, description) VALUES
(1, 0, '总经办', '张明远', 5, '公司战略决策与经营管理'),
(2, 1, '技术研发中心', '李泽宇', 50, '核心产品架构、仓颉后端与Web研发'),
(3, 1, '人力资源部', '王静', 10, '招聘配置、薪酬绩效与员工关系'),
(4, 1, '市场与产品部', '赵晨', 25, '产品规划、品牌推广与商业化');

INSERT IGNORE INTO hr_position (id, pos_code, pos_name, dept_id, level_range, min_salary, max_salary) VALUES
(1, 'POS-CIO', '首席信息官', 1, 'M4', 25000.00, 45000.00),
(2, 'POS-DEV-CJ', '仓颉后端工程师', 2, 'P6-P8', 15000.00, 32000.00),
(3, 'POS-DEV-FE', '资深前端工程师', 2, 'P6-P7', 14000.00, 28000.00),
(4, 'POS-HRBP', '资深 HRBP', 3, 'P6-P7', 10000.00, 18000.00),
(5, 'POS-PM', '高级产品经理', 4, 'P6-P8', 16000.00, 30000.00);

INSERT IGNORE INTO hr_employee (id, emp_no, name, gender, phone, email, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, contract_end_date, status) VALUES
(1, 'EMP20260001', '张明远', 1, '13800000001', 'admin@hrms.local', 1, 1, '首席信息官', 30000.00, 10.0, '2023-01-10', '2028-01-09', 'ACTIVE'),
(2, 'EMP20260002', '王静', 2, '13800000002', 'hr@hrms.local', 3, 4, '资深 HRBP', 14000.00, 8.0, '2023-06-01', '2027-05-31', 'ACTIVE'),
(3, 'EMP20260003', '李泽宇', 1, '13800000003', 'manager@hrms.local', 2, 2, '研发总监', 26000.00, 10.0, '2024-02-01', '2027-01-31', 'ACTIVE'),
(4, 'EMP20260004', '陈思远', 1, '13800000004', 'dev01@hrms.local', 2, 2, '仓颉后端工程师', 19000.00, 5.0, '2025-07-01', '2026-12-15', 'ACTIVE'),
(5, 'EMP20260005', '林小满', 2, '13800000005', 'fe01@hrms.local', 2, 3, '资深前端工程师', 17500.00, 5.0, '2026-09-01', '2029-08-31', 'PROBATION');

INSERT IGNORE INTO hr_recruitment_candidate (id, name, gender, phone, email, target_dept_id, target_position, expected_salary, source, stage, interview_notes) VALUES
(1, '周星辰', 1, '13911112222', 'zhou@example.com', 2, '仓颉后端工程师', 20000.00, 'BOSS直聘', 'OFFER', '技术面表现优秀，熟悉仓颉并发模型'),
(2, '吴雨桐', 2, '13933334444', 'wu@example.com', 4, '高级产品经理', 18000.00, '猎聘', 'INTERVIEW', '已完成一面，待复试');
