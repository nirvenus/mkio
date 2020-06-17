//Модуль для информационного обмена посредством МКИО с помощью микросхемы hi-1575
module hi_1575
(
input clock_100,
input clock_12,
input reset_b,

//Для взаимодействия с HI-1575
input pin_rcva,						// Принято сообщение по шине А
input pin_rcvb,						// Принято сообщение по шине B
output pin_reg,						// Настройка режима HI-1575 (1) / доступ к передаваемым данным (0)
output reg pin_r_w = 1'b1,					// чтение (1) / запись (0)
output reg pin_strb_n = 1'b1,				// Сигнал начала обмена данными
output reg pin_mr = 1'b1,					// Сброс HI-1575 (при лог. единице)
inout pin_sync,						// Синхронизация. 1 - командное слово, 0 - данные
inout [15 : 0] pin_d,				// Параллельный порт данных
output pin_clk_12,					// Тактовая частота для HI-1575
output reg pin_cha_chb = 1'b0,		// Выбор канала (0 - А, 1 - B)
//input pin_error,					// Goes high when a received MIL-STD-1553 word has an encoding error

//Для задания режима согласно протоколу
// ЧТЕНИЕ
output reg [15 : 0] data_rx = 16'h0,			// принятые данные
output reg cha_chb_rx = 1'b0,					// По какому каналу приняты данные (0 - А, 1 - B)
output reg [1 : 0] data_received_rx = 2'b0,		// принято слово (1 - слово данных, 3 - командное слово)

// ЗАПИСЬ
output reg ready_tx = 1'b0,			// МК готова для передачи данных
input cha_chb_tx,					// выбор канала (0 - А, 1 - B) для передачи
input [15 : 0] data_tx,				// данные для передачи
input command_word_tx,				// передаваемое слово является командным
input start_tx						// Начать передачу данных
);

assign pin_clk_12 = clock_12;	// тактируем МК
assign pin_reg = 1'b0;	// Без настройки МК

//-------------- Внутренние регистры и соединения

//Состояния для настройки микросхемы
logic [1 : 0] state = 2'd0;

localparam 	IDLE 							= 2'd0,
			WAIT_FOR_OPERATION				= 2'd1,
			DATA_WRITE						= 2'd2,
			DATA_READ						= 2'd3;

//Контроль переключения состояний
logic [15 : 0] data_to_transmit_tx = 16'h0;	// Данные для отправки на pin_d
logic command_word_to_transmit_tx = 1'b0;		// Командное или информационное слово для отправки
assign pin_d = (pin_r_w) ? (16'bz) : (data_to_transmit_tx);	// pin_r_w = 0 - отправляем данные data_to_transmit_tx
assign pin_sync = (pin_r_w) ? (1'bz) : (command_word_to_transmit_tx);	// pin_r_w = 0 - отправляем на линию тип данных: 0 - данные, 1 - командное слово

logic [5 : 0] counter_10_ns = 'd0;	// счетчик для 10 нсек при clock = 100 Мгц ЧТЕНИЕ/ЗАПИСЬ

// ТАЙМИНГИ
	// тайминги для ЧТЕНИЯ = 500 nsec
	localparam	t_strb_rx_start = 'd8,	// тактов до начала строба
				t_read_pin_d = 'd10 + t_strb_rx_start,		// тактов до чтения с "pin_d"
				t_strb_rx_stop = 'd12 + t_strb_rx_start,		// тактов до конца строба
				t_after_rx = 'd8 + t_strb_rx_stop;			// тактов до окончания состояния "DATA_READ"

	// тайминги для ЗАПИСИ	= 480 nsec
	localparam	t_strb_tx_start = 'd8,	// тактов до начала строба
				t_strb_tx_stop = 'd10 + t_strb_tx_start,	// тактов до конца строба
				t_after_strb_tx = 'd8 + t_strb_tx_stop,	// тактов после стоба
				t_after_tx = 'd8 + t_after_strb_tx;		// тактов до окончания состояния "DATA_WRITE"
				
always @(posedge clock_100, negedge reset_b) begin
	if (!reset_b) begin		
		pin_r_w 				<= 1'b1;	
		pin_strb_n 				<= 1'b1;	// строб 1 - пока ничего не делаем
		pin_mr					<= 1'b1;	// сбрасываем МК
		pin_cha_chb				<= 1'b0;	// Канал А по умолчанию
		cha_chb_rx 				<= 1'b0;	// По какому каналу приняты данные (0 - А, 1 - B)
		data_rx					<= 16'h0;	// Обнуляем считанные с МК данные
		data_to_transmit_tx		<= 16'h0;	// пока нет данных не передачу	
		command_word_to_transmit_tx <= 1'b0;		// Командное слово для отправки или нет
		data_received_rx		<= 2'h0;
		ready_tx 				<= 1'b0;	// Готовность МК к передаче
		
		counter_10_ns 			<= 'd0;	// счетчик для DATA_WRITE, DATA_READ, READ_SAM
		
		// переход
			state				<= IDLE;

	end
	else begin
		case(state)		
//Настройка
			IDLE: begin		// 0
				pin_r_w 				<= 1'b1;
				pin_strb_n 				<= 1'b1;	// строб 1 - пока ничего не делаем
				pin_mr					<= 1'b0;	// сбрасываем МК
				pin_cha_chb				<= 1'b0;	// Канал А по умолчанию
				cha_chb_rx 				<= 1'b0;	// По какому каналу приняты данные (0 - А, 1 - B)
				data_rx					<= 16'h0;	// Обнуляем считанные с МК данные
				data_received_rx		<= 2'h0;	// какое слово получено
				data_to_transmit_tx		<= 16'h0;	// пока нет данных не передачу
				command_word_to_transmit_tx <= 1'b0;		// Командное слово для отправки или нет
				ready_tx 				<= 1'b0;	// Готовность МК к передаче
				
				counter_10_ns 			<= 'd0;	// счетчик для DATA_WRITE, DATA_READ, READ_SAM
				
				// переход
					state				<= WAIT_FOR_OPERATION;
			end
			
// ОЖИДАНИЕ КОМАНДЫ НА ЗАПИСЬ ИЛИ ЧТЕНИЕ
			WAIT_FOR_OPERATION: begin	// 3
				if (start_tx) begin	// передача данных
					pin_cha_chb					<= cha_chb_tx;	// Канал для передачи (0 - А, 1 - B)
					pin_r_w 					<= 1'b0;		// Запись данных
					data_to_transmit_tx 		<= data_tx;		// обнуляем данные на передачу
					command_word_to_transmit_tx <= command_word_tx;	// Командное слово для отправки или нет
					ready_tx 					<= 1'b0;		// Готовность МК к передаче
					
					// переход
						state <= DATA_WRITE;
				end
				else if (pin_rcva | pin_rcvb) begin	// Прием данных, если нет передачи
					data_received_rx		<= 2'h0;		// пока не приняты данные
					pin_cha_chb				<= pin_rcvb;	// По какому каналу будем читать данные (0 - А, 1 - B)
					pin_r_w 				<= 1'b1;		// чтение данных
					
					ready_tx 				<= 1'b0;		// Готовность МК к передаче
					
					// переход
						state <= DATA_READ;
				end
				else begin
					ready_tx 				<= 1'b1;	// Готовность МК к передаче
					
					counter_10_ns 			<= 'd0;		// счетчик для DATA_WRITE, DATA_READ, READ_SAM
					
					// переход				
						state <= WAIT_FOR_OPERATION;
				end
			end
			
// ЗАПИСЬ ДАННЫХ
			DATA_WRITE: begin	// 4
				pin_r_w 					<= (counter_10_ns < t_after_strb_tx) ? (1'b0) : (1'b1);	// запись данных
				pin_strb_n					<= (t_strb_tx_start <= counter_10_ns && counter_10_ns <= t_strb_tx_stop) ? (1'b0) : (1'b1);	// строб записи
				
				if (counter_10_ns < t_after_tx) begin
					counter_10_ns <= counter_10_ns + 6'd1;
					
					// переход
						state <= DATA_WRITE;
					
				end
				else begin
					counter_10_ns 			<= 'd0;			// обнуляем счетчик
					
					// переход
						state <= WAIT_FOR_OPERATION;
				end
			end
			
// ЧТЕНИЕ ДАННЫХ
			DATA_READ: begin	// 5
				pin_strb_n				<= (t_strb_rx_start <= counter_10_ns && counter_10_ns <= t_strb_rx_stop) ? (1'b0) : (1'b1);	// строб чтения
				// Чтение
				if (counter_10_ns == t_read_pin_d) begin
					data_rx 				<=	pin_d;		// чтение данных
					data_received_rx[1] 	<=	pin_sync;	// флаг - командное слово
				end
				
				if (counter_10_ns < t_after_rx) begin
					counter_10_ns <= counter_10_ns + 6'd1;
					
					// переход
						state <= DATA_READ;
				end
				else begin
					data_received_rx[0] 	<= 1'b1;			// флаг - принято сообщение
					cha_chb_rx 				<= pin_cha_chb;		// По какому каналу приняты данные (0 - А, 1 - B)

					counter_10_ns 			<= 'd0;	// обнуляем счетчик
						
					// переход
						state <= WAIT_FOR_OPERATION;
				end
			end			

			default: state <= IDLE;
			
		endcase
	end
end
			
endmodule