(************************************************
				RequestHandlers.wl
*************************************************
Description:
	Handlers for message frames of type
		"x_request" arriving from Jupyter
Symbols defined:
	executeRequestHandler,
	completeRequestHandler
*************************************************)

(************************************
	Get[] guard
*************************************)

If[
	!TrueQ[WolframLanguageForJupyter`Private`$GotRequestHandlers],
	
	WolframLanguageForJupyter`Private`$GotRequestHandlers = True;

(************************************
	load required
		WolframLanguageForJupyter
		files
*************************************)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "Initialization.wl"}]]; (* loopState *)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "SocketUtilities.wl"}]]; (* sendFrame *)
	Get[FileNameJoin[{DirectoryName[$InputFileName], "MessagingUtilities.wl"}]]; (* createReplyFrame *)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "EvaluationUtilities.wl"}]]; (* simulatedEvaluate *)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "OutputHandlingUtilities.wl"}]]; (* textQ, mathExprQ, toOutText, toOutImage, toOutMathML, containsPUAQ *)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "CompletionUtilities.wl"}]]; (* rewriteNamedCharacters *)

(************************************
	private symbols
*************************************)

	(* begin the private context for WolframLanguageForJupyter *)
	Begin["`Private`"];

(************************************
	handler for execute_requests
*************************************)

	(* handle execute_request messages frames received on the shell socket *)
	executeRequestHandler[] :=
		Module[
			{
				(* content of the desired frame to send on the IO Publish socket *)
				ioPubReplyContent,

				(* the HTML form for any generated message *)
				errorMessage,

				(* the total result of the evaluation:
					an association containing
						the result of evaluation ("EvaluationResult"),
						indices of the output lines of the result ("EvaluationResultOutputLineIndices"),
						the total number of indices consumed by this evaluation ("ConsumedIndices"),
						generated messages ("GeneratedMessages")
				*)
				totalResult
			},

			(* set the appropriate reply type *)
			loopState["replyMsgType"] = "execute_reply";

			(* set the content of the reply to information about WolframLanguageForJupyter's execution of the input *)
			loopState["replyContent"] = 
				ExportString[
					Association[
						"status" -> "ok",
						"execution_count" -> loopState["executionCount"],
						"user_expressions" -> {}
					], 
					"JSON",
					"Compact" -> True
				];

			(* redirect Print so that it prints in the Jupyter notebook *)
			loopState["printFunction"] = 
				(
					(* send a frame *)
					sendFrame[
						(* on the IO Publish socket *)
						ioPubSocket,
						(* create the frame *)
						createReplyFrame[
								(* using the current source frame *)
								loopState["frameAssoc"],
								(* see https://jupyter-client.readthedocs.io/en/stable/messaging.html#streams-stdout-stderr-etc *)
								(* with a message type of "stream" *)
								"stream",
								(* and with message content that tells Jupyter what to Print, and to use stdout *)
								ExportString[
									Association[
											"name" -> "stdout",
											"text" -> #1
									],
									"JSON",
									"Compact" -> True
								],
								(* and without branching off *)
								False
						]
					]
					&
				);

			(* evaluate the input, and store the total result in totalResult *)
			totalResult = simulatedEvaluate[loopState["frameAssoc"]["content"]["code"]];
			
			(* restore printFunction to empty *)
			loopState["printFunction"] = Function[#;];

			(* generate an HTML form of the message text *)
			errorMessage =
				If[StringLength[totalResult["GeneratedMessages"]] == 0,
					(* if there are no messages, no need to format anything *)
					{},
					(* build the HTML form of the message text *)
					{
						(* preformatted *)
						"<pre style=\"",
						(* the color of the text should be red, and should use Courier *)
						StringJoin[{"&#",ToString[#1], ";"} & /@ ToCharacterCode["color:red; font-family: \"Courier New\",Courier,monospace;", "UTF-8"]], 
						(* end pre tag *)
						"\">",
						(* the generated messages  *)
						StringJoin[{"&#", ToString[#1], ";"} & /@ ToCharacterCode[totalResult["GeneratedMessages"], "UTF-8"]],
						(* end the element *)
						"</pre>"
					}
				];

			(* if there are no results, do not send anything on the IO Publish socket and return *)
			If[
				Length[totalResult["EvaluationResultOutputLineIndices"]] == 0,
				(* increment loopState["executionCount"] as needed *)
				loopState["executionCount"] += totalResult["ConsumedIndices"];
				Return[];
			];

			(* format output as purely text, image, or cloud interface *)
			If[
				(* check if the input was wrapped with Interact,
					which is used when the output should be displayed as an embedded cloud object *)
				TrueQ[totalResult["InteractStatus"]] && 
					(* check if we are logged into the Cloud *)
					$CloudConnected,
				(* prepare the content for a reply message frame to be sent on the IO Publish socket *)
				ioPubReplyContent =
					ExportString[
						Association[
							(* the first output index *)
							"execution_count" -> First[totalResult["EvaluationResultOutputLineIndices"]],
							(* HTML code to embed output uploaded to the Cloud in the Jupyter notebook *)
							"data" ->
								{"text/html" ->
									StringJoin[
										(* display any generated messages as inlined PNG images encoded in base64 *)
										"<div><img alt=\"\" src=\"data:image/png;base64,", 
										(* rasterize the generated messages in a dark red color, and convert the resulting image to base64*)
										BaseEncode[ExportByteArray[Rasterize[Style[totalResult["GeneratedMessages"], Darker[Red]]], "PNG"]],
										(* end image element *)
										"\">",
										(* embed the cloud object *)
										EmbedCode[CloudDeploy[totalResult["EvaluationResult"]], "HTML"][[1]]["CodeSection"]["Content"],
										(* end the whole element *)
										"</div>"
									]
								},
							(* no metadata *)
							"metadata" -> {"text/html" -> {}}
						],
						"JSON",
						"Compact" -> True
					];
				,
				(* if every output line can be formatted as text, use a function that converts the output to text *)
				(* TODO: allow for mixing text and image results *)
				(* otherwise, use a function that converts the output to an image *)
				If[AllTrue[totalResult["EvaluationResult"], textQ],
					toOut = toOutText,
					If[mathExprQ[totalResult["EvaluationResult"]],
						toOut = toOutMathML,
						toOut = toOutImage
					]
				];
				(* prepare the content for a reply message frame to be sent on the IO Publish socket *)
				ioPubReplyContent = ExportString[
					Association[
						(* the first output index *)
						"execution_count" -> First[totalResult["EvaluationResultOutputLineIndices"]],
						(* generate HTML of results and messages *)
						"data" ->
							{"text/html" ->
								(* output the results in a grid *)
								If[
									Length[totalResult["EvaluationResult"]] > 1,
									StringJoin[
										(* add grid style *)
										"<style>
											.grid-container {
												display: inline-grid;
												grid-template-columns: auto;
											}
										</style>

										<div>",
										(* display error message *)
										errorMessage,
										(* start the grid *)
										"<div class=\"grid-container\">",
										(* display the output lines *)
										Table[
											{
												(* start the grid item *)
												"<div class=\"grid-item\">",
												(* show the output line *)
												toOut[totalResult["EvaluationResult"][[outIndex]]],
												(* end the grid item *)
												"</div>"
											},
											{outIndex, 1, Length[totalResult["EvaluationResult"]]}
										],
										(* end the element *)
										"</div></div>"
									],
									StringJoin[
										(* start the element *)
										"<div>",
										(* display error message *)
										errorMessage,
										(* if there are messages, but no results, do not display a result *)
										If[
											Length[totalResult["EvaluationResult"]] == 0,
											"",
											(* otherwise, display a result *)
											toOut[First[totalResult["EvaluationResult"]]]
										],
										(* end the element *)
										"</div>"
									]
								]
							},
						(* no metadata *)
						"metadata" -> {"text/html" -> {}}
					],
					"JSON",
					"Compact" -> True
				];
			];

			(* create frame from ioPubReplyContent *)
			loopState["ioPubReplyFrame"] = 
				createReplyFrame[
					(* use the current source frame *)
					loopState["frameAssoc"],
					(* the reply message type *)
					"execute_result",
					(* the reply message content *)
					ioPubReplyContent,
					(* do not branch off *)
					False
				];

			(* increment loopState["executionCount"] as needed *)
			loopState["executionCount"] += totalResult["ConsumedIndices"];
		];

(************************************
	handler for complete_requests
*************************************)

	(* handle complete_request messages frames received on the shell socket *)
	completeRequestHandler[] :=
		Module[
			{
				(* for storing the code string to offer completion suggestions on *)
				codeStr
			},
			(* get the code string to rewrite the named characters of, ending at the cursor *)
			codeStr =
				StringTake[
					loopState["frameAssoc"]["content"]["code"],
					{
						1,
						loopState["frameAssoc"]["content"]["cursor_pos"]
					}
				];
			(* set the appropriate reply type *)
			loopState["replyMsgType"] = "complete_reply";
			(* set the content of the reply to a list of rewrites for any named characters in the code string *)
			loopState["replyContent"] = 
				ByteArrayToString[
					ExportByteArray[
						Association[
							"matches" ->
								DeleteDuplicates[
									Prepend[
										Select[
											rewriteNamedCharacters[codeStr],
											(!containsPUAQ[#1])&
										],
										codeStr
									]
								],
							"cursor_start" -> 0,
							"cursor_end" -> StringLength[codeStr],
							"metadata" -> {},
							"status" -> "ok"
						], 
						"JSON",
						"Compact" -> True
					]
				];
		];

	(* end the private context for WolframLanguageForJupyter *)
	End[]; (* `Private` *)

(************************************
	Get[] guard
*************************************)

] (* WolframLanguageForJupyter`Private`$GotRequestHandlers *)
