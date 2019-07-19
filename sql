DELIMITER $$

USE `sh_process`$$

DROP PROCEDURE IF EXISTS `d_op_area_shelf_product_unsale_flag`$$

CREATE DEFINER=`feprocess`@`%` PROCEDURE `d_op_area_shelf_product_unsale_flag`()
    SQL SECURITY INVOKER
BEGIN
	DECLARE l_test VARCHAR(1);
        DECLARE l_row_cnt INT;
        DECLARE CODE CHAR(5) DEFAULT '00000';
        DECLARE done INT;

        DECLARE l_table_owner   VARCHAR(64);
        DECLARE l_city          VARCHAR(64);
        DECLARE l_task_name     VARCHAR(64);
                DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
                DECLARE EXIT HANDLER FOR SQLEXCEPTION
                BEGIN
                        GET DIAGNOSTICS CONDITION 1
                        CODE = RETURNED_SQLSTATE,@x2 = MESSAGE_TEXT;
                        CALL sh_process.sp_stat_err_log_info(l_task_name,@x2); 
                       # CALL feods.sp_event_task_log(l_task_name,l_state_date_hour,3);
                END; 
        SET l_task_name = 'd_op_area_shelf_product_unsale_flag';

  DROP TEMPORARY TABLE IF EXISTS feods.`d_op_shelf_product_unsale_tmp`;
  CREATE TEMPORARY TABLE feods.d_op_shelf_product_unsale_tmp (
        PRIMARY KEY (`id`),
        KEY idx_shelf_id (shelf_id),
        KEY idx_product_id(product_id)
        ) AS
SELECT 
        t1.shelf_id,
        t1.product_id
FROM fe.`sf_shelf_product_detail` t1
JOIN fe.sf_shelf_product_detail_flag t2
ON t1.SHELF_ID = t2.SHELF_ID AND t1.PRODUCT_ID = t2.PRODUCT_ID
WHERE t2.SALES_FLAG = 5 
        AND t2.NEW_FLAG = 2 
        AND t1.STOCK_QUANTITY > 0
        AND t1.data_flag = 1
        AND t2.data_flag = 1
    ;

  DROP TEMPORARY TABLE IF EXISTS feods.`d_op_shelf_product_unsale_flag_tmp`;
  CREATE TEMPORARY TABLE feods.d_op_shelf_product_unsale_flag_tmp (
        PRIMARY KEY (`id`),
        UNIQUE KEY `uk_shelf_product_id` (`shelf_id`,`product_id`) ,
        KEY `idx_fill_type` (`fill_type`),
        KEY `idx_apply_time` (`apply_time`),
        KEY `idx_fill_type_apply_time` (`fill_type`,`apply_time`)
        ) AS
SELECT 
        t1.shelf_id,
        t1.product_id,
        t4.fill_type,
        t4.apply_time
FROM feods.`d_op_shelf_product_unsale_tmp` t1
JOIN fe.`sf_product_fill_order_item` t3
        ON t1.`SHELF_ID` = t3.SHELF_ID AND t1.PRODUCT_ID = t3.PRODUCT_ID
JOIN fe.`sf_product_fill_order` t4
        ON t3.ORDER_ID = t4.ORDER_ID
WHERE 
        t3.data_flag = 1   
        AND t4.data_flag = 1 
    ;

TRUNCATE feods.d_op_area_shelf_product_unsale_flag;
INSERT INTO feods.d_op_area_shelf_product_unsale_flag
(
        business_area,
        shelf_id,
        product_id,
        unsale_reason_flag
)	
SELECT 
        c.BUSINESS_AREA,
        p.shelf_id,
        p.product_id,
        MIN(unsale_reason_flag) AS unsale_reason_flag      -- 按滞销品原因选择最小优先级
FROM
(
        -- 1.淘汰商品再上架
        -- 历史货架单品标识为淘汰，现为非淘汰
        SELECT 
                a.business_area,
                c.shelf_id,
                a.PRODUCT_ID,
                1 AS unsale_reason_flag
        FROM feods.`zs_product_dim_sserp` a
        JOIN feods.`zs_product_dim_sserp_his` b 
                ON a.business_area=b.business_area AND a.PRODUCT_ID = b.PRODUCT_ID
        JOIN 
                (
                        SELECT 
                                t4.`BUSINESS_AREA`,
                                t1.shelf_id,
                                t1.product_id
                        FROM feods.`d_op_shelf_product_unsale_tmp` t1
                        JOIN fe.`sf_shelf` t3
                                ON t1.`SHELF_ID` = t3.`SHELF_ID` 
                        JOIN fe.zs_city_business t4
                                ON t4.`CITY_NAME`= SUBSTRING_INDEX(SUBSTRING_INDEX(t3.AREA_ADDRESS,',',2),',',-1)
                        WHERE t3.data_flag = 1
                ) c
                ON a.business_area=c.business_area AND a.PRODUCT_ID = c.PRODUCT_ID
        WHERE b.product_type = '淘汰（替补）' AND a.product_type <> '淘汰（替补）'
        UNION ALL
        -- 2.新品引进异常
        -- 地区初始商品包补货，且严重滞销货架占比85%
        SELECT 
                DISTINCT a.business_area,
                c.shelf_id,
                a.product_id,
                2 AS unsale_reason_flag
        FROM 
                (
                        SELECT 
                                t4.BUSINESS_AREA,
                                t1.product_id,
                                COUNT(CASE WHEN t2.sales_flag = 5 THEN 1 END) / COUNT(t1.shelf_id) AS unsale_rate
                        FROM fe.`sf_shelf_product_detail` t1
                        JOIN fe.sf_shelf_product_detail_flag t2
                                ON t1.SHELF_ID = t2.SHELF_ID AND t1.PRODUCT_ID = t2.PRODUCT_ID
                        JOIN fe.`sf_shelf` t3
                                ON t1.`SHELF_ID` = t3.`SHELF_ID` 
                        JOIN fe.zs_city_business t4
                                ON SUBSTRING_INDEX(SUBSTRING_INDEX(t3.AREA_ADDRESS,',',2),',',-1) = t4.`CITY_NAME`     
                        WHERE t2.NEW_FLAG = 2 
                                AND t1.STOCK_QUANTITY > 0
                                AND t1.data_flag = 1
                                AND t2.data_flag = 1        
                                AND t3.data_flag = 1
                        GROUP BY t4.BUSINESS_AREA,t1.product_id
                ) a
                JOIN
                (
                        SELECT 
                                t4.BUSINESS_AREA,
                                t1.shelf_id,
                                t1.product_id
                        FROM feods.`d_op_shelf_product_unsale_tmp` t1
                        JOIN fe.`sf_shelf` t3
                                ON t1.`SHELF_ID` = t3.`SHELF_ID` 
                        JOIN fe.zs_city_business t4
                                ON SUBSTRING_INDEX(SUBSTRING_INDEX(t3.AREA_ADDRESS,',',2),',',-1) = t4.`CITY_NAME`  
                )  c     
                        ON a.BUSINESS_AREA = c.BUSINESS_AREA
                                AND a.product_id = c.product_id
        JOIN fe.`sf_product_fill_order` b
                ON c.shelf_id = b.shelf_id
        WHERE a.unsale_rate > 0.85 
                AND b.fill_type = 3
                AND b.data_flag = 1
        UNION ALL
        --  3：包盗损无销售
        -- 匹配包盗损清单（风控导入系统）

        SELECT 
                '' AS business_area,
                a.shelf_id,                                                                                                        
                b.product_id,
                3 AS unsale_reason_flag 
        FROM feods.`d_op_risk_sc_temp` a
        JOIN fe.`sf_shelf_product_detail` b
                ON a.shelf_id = b.shelf_id
        WHERE a.version_id = 201901  
                AND b.STOCK_QUANTITY > 0
                AND b.data_flag = 1
        UNION ALL
        -- 4.虚库存
        -- 非整箱补货，且前两月非滞销（1,2,3），当前严重滞销，库存数量<2
        SELECT 
                '' AS business_area,
                a.shelf_id,
                a.product_id,
                4 AS unsale_reason_flag
        FROM
        (
                SELECT 
                        t1.shelf_id,
                        t1.product_id
                FROM feods.`d_op_shelf_product_unsale_tmp` t1
                JOIN fe.`sf_shelf_product_detail` t2
                ON t1.SHELF_ID = t2.SHELF_ID AND t1.PRODUCT_ID = t2.PRODUCT_ID
                WHERE t2.STOCK_QUANTITY < 2
        ) a
        JOIN 
        (
                SELECT 
                        shelf_id,
                        product_id 
                FROM fe.`sf_shelf_product_weeksales_detail`
                WHERE sales_flag IN (1,2,3) 
                        AND stat_date = DATE_SUB(
                                DATE_SUB(CURDATE(),INTERVAL 2 MONTH),
                                INTERVAL WEEKDAY(
                                        DATE_SUB(CURDATE(),INTERVAL 2 MONTH)
                                ) +1 DAY)       # 匹配两个月前的周日截存的数据
        ) b
                ON a.SHELF_ID = b.SHELF_ID AND a.PRODUCT_ID = b.PRODUCT_ID
        JOIN fe.`sf_product` c
                ON a.PRODUCT_ID = c.PRODUCT_ID
        WHERE c.DATA_FLAG = 1 AND c.FILL_MODEL <= 1
        UNION ALL
        -- 整箱补货，且前两月非滞销（1,2,3），当前严重滞销，库存数量<=2
        SELECT 
                '' AS business_area,
                a.shelf_id,
                a.product_id,
                4 AS unsale_reason_flag
        FROM
        (  
                SELECT 
                        t1.shelf_id,
                        t1.product_id
                FROM feods.`d_op_shelf_product_unsale_tmp` t1
                JOIN fe.`sf_shelf_product_detail` t2
                ON t1.SHELF_ID = t2.SHELF_ID AND t1.PRODUCT_ID = t2.PRODUCT_ID
                WHERE t2.STOCK_QUANTITY <= 2
        ) a
        JOIN 
        (
                SELECT 
                        shelf_id,
                        product_id 
                FROM fe.`sf_shelf_product_weeksales_detail`
                WHERE sales_flag IN (1,2,3) 
                        AND stat_date = DATE_SUB(
                                DATE_SUB(CURDATE(),INTERVAL 2 MONTH),
                                INTERVAL WEEKDAY(
                                        DATE_SUB(CURDATE(),INTERVAL 2 MONTH)
                                ) +1 DAY)       # 匹配两个月前的周日截存的数据
        ) b
                ON a.SHELF_ID = b.SHELF_ID AND a.PRODUCT_ID = b.PRODUCT_ID
        JOIN fe.`sf_product` c
                ON a.PRODUCT_ID = c.PRODUCT_ID
        WHERE c.DATA_FLAG = 1 AND c.FILL_MODEL > 1
        UNION ALL
        -- 5：采购集中清理
        -- 采购将某些商品集中到一个货架集中清理
        SELECT 
                '' AS business_area,
                a.shelf_id,
                b.product_id,
                5 AS unsale_reason_flag 
        FROM feods.`d_op_risk_sc_temp` a
        JOIN fe.`sf_shelf_product_detail` b
                ON a.shelf_id = b.shelf_id
        WHERE version_id = 201902 
                AND b.STOCK_QUANTITY > 0
                AND b.data_flag = 1
        UNION ALL
        -- 6.店主异常调货
        -- 订单类型：来源地货架
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                6 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type IN (6,7)
        UNION ALL
        -- 7.撤架    
        -- 订单类型：撤架   
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                7 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE 
        t1.fill_type IN (4,5) 
        UNION ALL
        --  8.销售下滑
        -- 订单类型：系统触发，且当前日期-最后一次下单时间>=30天
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                8 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type = 2
                AND t1.apply_time <= DATE_SUB(CURDATE(),INTERVAL 30 DAY)
        UNION ALL
        -- 9.系统逻辑异常
        -- 订单类型：系统触发，且当前日期-最后一次下单时间<30天
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                9 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type = 2
                AND t1.apply_time > DATE_SUB(CURDATE(),INTERVAL 30 DAY)
        UNION ALL
        -- 10.地区补货人员补货异常
        -- 订单类型：人工申请
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                10 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type =1
        UNION ALL
        -- 11.前置站站长补货异常
        -- 订单类型：前置站调货
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                11 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type IN (9,10)
        UNION ALL
        -- 12.店主补货异常
        -- 订单类型：要货
        SELECT 
                '' AS business_area,
                t1.shelf_id,
                t1.product_id,
                12 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_flag_tmp` t1
        WHERE t1.fill_type = 8 
        UNION ALL
        -- 13.箱规格过大
        -- 首次补货（只补过1次货），当前严重滞销（盒装商品补货规格>10)
        SELECT 
                '' AS business_area,
                a.shelf_id,
                a.product_id,
                13 AS unsale_reason_flag
        FROM feods.`d_op_shelf_product_unsale_tmp` a
        JOIN 
        (
                SELECT 
                        t1.shelf_id
                FROM
                (
                        SELECT 
                                MAX(sdate) AS sdate,
                                shelf_id,
                                MAX(orders_cum) AS orders_cum
                        FROM feods.fjr_fill_shelf_stat
                        GROUP BY shelf_id
                        ORDER BY shelf_id, sdate DESC
                ) t1
                WHERE t1.orders_cum = 1
        ) b
                ON a.shelf_id = b.shelf_id
        JOIN
        (
                SELECT product_id
                FROM fe.`sf_product` p
                WHERE FILL_UNIT='盒' 
                        AND FILL_MODEL >10 
                        AND DATA_FLAG=1
        ) c
                ON a.product_id = c.product_id
) p
JOIN fe.sf_shelf b
        ON p.shelf_id=b.shelf_id AND b.data_flag = 1
JOIN fe.zs_city_business c 
        ON c.city_name = SUBSTRING_INDEX(SUBSTRING_INDEX(b.AREA_ADDRESS, ',', 2),',',-1)
GROUP BY c.BUSINESS_AREA,p.shelf_id,p.product_id;
        
COMMIT;
	END$$

DELIMITER ;
