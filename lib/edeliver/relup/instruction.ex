defmodule Edeliver.Relup.Instruction do
  @moduledoc """
    This module can be used to provide custom instructions
    to modify the relup. They can be used the the implementation
    of the Edeliver.Relup.Modifcation module.

    Example:

      defmodule Acme.Relup.LogUpgradeInstruction do
        use Edeliver.Relup.Instruction

        def modify_relup(instructions = %Instructions{up_instructions: up_instructions}, _config = %Config{}) do
          log_instruction = {:apply, {:"Elixir.Logger", :info, [<<"Upgraded successfully">>]}}
          %{instructions| up_instructions: [log_instruction|up_instructions]}
        end

      end

      # using the instruction
      defmodule Acme.Relup.Modification do
        use Edeliver.Relup.Modification

        def modify_relup(instructions = %Instructions{}, _config = %Config{}) do
          instructions |> Edeliver.Relup.DefaultModification.modify_relup(Config) # use default modifications
                       |> Acme.Relup.LogUpgradeInstruction.modify_relup(Config) # apply also custom instructions
        end
      end

  """
  use Behaviour

  @callback modify_relup(Edeliver.Relup.Instructions.t, ReleaseManager.Config.t) :: Edeliver.Relup.Instructions.t

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Edeliver.Relup.Instruction
      alias Edeliver.Relup.Instructions
      alias ReleaseManager.Config

      @type instruction :: :relup.instruction
      @type instructions :: [instruction]

      @type insert_fun :: ((%Instructions{}|instructions, new_instructions::instruction|instructions) -> updated_instructions::%Instructions{}|instructions)

      @doc """
        Inserts an instruction or a list of instructions before the point of no return. All instructions
        running before that point of no return which fail will cause the upgrade to fail, while
        failing instructions running after that point will cause the node to restart the release.
      """
      @spec insert_before_point_of_no_return(%Instructions{}|instructions, new_instructions::instruction|instructions) :: updated_instructions::%Instructions{}|instructions
      def insert_before_point_of_no_return(instructions = %Instructions{}, new_instructions) do
        %{instructions|
          up_instructions:   insert_before_point_of_no_return(instructions.up_instructions,   new_instructions),
          down_instructions: insert_before_point_of_no_return(instructions.down_instructions, new_instructions)
        }
      end
      def insert_before_point_of_no_return(existing_instructions, new_instructions) do
        insert_before_instruction(existing_instructions, new_instructions, :point_of_no_return)
      end

      @doc """
        Inserts an instruction or a list of instructions right after the point of no return.
        This means that it is the first instruction which should not fail, because the release
        handler will restart the release if any instruction fails after the point
        of no return.
      """
      @spec insert_after_point_of_no_return(%Instructions{}|instructions, new_instructions::instruction|instructions) :: updated_instructions::%Instructions{}|instructions
      def insert_after_point_of_no_return(instructions = %Instructions{}, new_instructions) do
        %{instructions|
          up_instructions:   insert_after_point_of_no_return(instructions.up_instructions,   new_instructions),
          down_instructions: insert_after_point_of_no_return(instructions.down_instructions, new_instructions)
        }
      end
      def insert_after_point_of_no_return(existing_instructions, new_instructions) do
        insert_after_instruction(existing_instructions, new_instructions, :point_of_no_return)
      end

      @doc """
        Inserts an instruction or a list of instructions right after the last `load_object_code`
        instruction which is usually before the "point of no return" and one of the first instructions.
        This means that it is the first custom instruction which is executed. It is executed twice,
        once when checking whether the upgrade can be installed and once when the upgrade is installed.
      """
      @spec insert_after_load_object_code(%Instructions{}|instructions, new_instructions::instruction|instructions) :: updated_instructions::%Instructions{}|instructions
      def insert_after_load_object_code(instructions = %Instructions{}, new_instructions) do
        %{instructions|
          up_instructions:   insert_after_load_object_code(instructions.up_instructions,   new_instructions),
          down_instructions: insert_after_load_object_code(instructions.down_instructions, new_instructions)
        }
      end
      def insert_after_load_object_code(existing_instructions, new_instructions) do
        last_load_object_code_instruction = existing_instructions |> Enum.reverse |> List.keyfind(:load_object_code, 0)
        if last_load_object_code_instruction do
          insert_after_instruction(existing_instructions, new_instructions, last_load_object_code_instruction)
        else
          append(existing_instructions, new_instructions)
        end
      end

      @doc """
        Appends an instruction or a list of instructions to the instruction after the
        "point of no return" but before any instruction which:
          - loads or unloads new code, which means before any
              `load_module`, `load`, `add_module`, `delete_module`,
              `remove`, `purge` instruction and
          - before any instruction which updates, starts or stops
            any running processes, which means before any
              `code_change`, `update`, `start`, `stop` instruction and
          - before any instruction which (re-)starts or stops
            any application or the emulator, which means before any
              `add_application`, `remove_application`, `restart_application`,
              `restart_emulator` and `restart_new_emulator` instruction.

        It does not consider load-instructions for `Edeliver.Relup.RunnableInstruction`s
        as code loading instructions for the release. They are inserted by the
        `RunnableInstruction` itself to ensure that the code of the runnable instruction
        is loaded before the instruction is executed. See `ensure_module_loaded_before_instruction/2`.
      """
      @spec append_after_point_of_no_return(%Instructions{}|instructions, new_instructions::instruction|instructions) :: updated_instructions::%Instructions{}|instructions
      def append_after_point_of_no_return(instructions = %Instructions{}, new_instructions) do
        %{instructions|
          up_instructions:   append_after_point_of_no_return(instructions.up_instructions,  new_instructions),
          down_instructions: append_after_point_of_no_return(instructions.down_instructions, new_instructions)
        }
      end
      def append_after_point_of_no_return(existing_instructions, new_instruction) when is_list(existing_instructions) and not is_list(new_instruction) do
        append_after_point_of_no_return(existing_instructions, [new_instruction])
      end
      def append_after_point_of_no_return(existing_instructions, new_instructions) when is_list(existing_instructions) do
        append_after_point_of_no_return(existing_instructions, new_instructions, false, [])
      end

      defp append_after_point_of_no_return(_existing_instructions = [:point_of_no_return|rest], new_instructions, _after_point_of_no_return = false, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, true, [:point_of_no_return|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [instruction|rest], new_instructions, after_point_of_no_return = false, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [instruction|instructions_before_instruction])
      end
      # skip instructions which loads code and are inserted before a runnable instruction. see `Edeliver.Relup.RunnableInstruction`
      # and `Edeliver.Relup.Instruction.ensure_module_loaded_before_instruction/2`. That load instructions are inserted by the
      # `RunnableInstruction` itself and are not considered to be a 'real' code loading instruction for the running application.
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:load_module, module}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:load_module, module, _dep_mods}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:load_module, module, _pre_purge, _post_purge, _dep_mods}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:add_module, module}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:add_module, module, _dep_mods}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      defp append_after_point_of_no_return(_existing_instructions = [load_runnable_instruction = {:load, {module, _pre_purge, _post_purge}}, runnable_instruction = {:apply, {module, :run, _args}}|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [runnable_instruction, load_runnable_instruction|instructions_before_instruction])
      end
      # check whether the instruction is an instruction modifying code, processes or applications
      defp append_after_point_of_no_return(existing_instructions = [instruction|rest], new_instructions, after_point_of_no_return = true, instructions_before_instruction) do
        if modifies_code?(instruction) or modifies_processes?(instruction) or modifies_applications?(instruction) do
          Enum.reverse(instructions_before_instruction) ++ new_instructions ++ existing_instructions
        else
          append_after_point_of_no_return(rest, new_instructions, after_point_of_no_return, [instruction|instructions_before_instruction])
        end
      end
      defp append_after_point_of_no_return(_existing_instructions = [], new_instructions, _after_point_of_no_return, instructions_before_instruction) do
        Enum.reverse(instructions_before_instruction) ++ new_instructions
      end

      @doc """
        Appends an instruction or a list of instructions to the list of other instructions.
      """
      @spec append(%Instructions{}|instructions, new_instructions::instruction|instructions) :: updated_instructions::%Instructions{}|instructions
      def append(instructions = %Instructions{}, new_instructions) do
        %{instructions|
          up_instructions:   append(instructions.up_instructions,  new_instructions),
          down_instructions: append(instructions.down_instructions, new_instructions)
        }
      end
      def append(existing_instructions, new_instruction) when is_list(existing_instructions) and not is_list(new_instruction) do
        append(existing_instructions, [new_instruction])
      end
      def append(existing_instructions, new_instructions) when is_list(existing_instructions) do
        existing_instructions ++ new_instructions
      end


      @doc """
        Inserts an instruction or a list of instructions before the given instruction.
      """
      @spec insert_before_instruction(%Instructions{}|instructions, new_instructions::instruction|instructions, before_instruction::instruction) :: updated_instructions::%Instructions{}|instructions
      def insert_before_instruction(instructions = %Instructions{}, new_instructions, before_instruction) do
        %{instructions|
          up_instructions:   insert_before_instruction(instructions.up_instructions,  new_instructions, before_instruction),
          down_instructions: insert_after_instruction(instructions.down_instructions, new_instructions, before_instruction)
        }
      end
      def insert_before_instruction(existing_instructions, new_instruction, before_instruction) when is_list(existing_instructions) and not is_list(new_instruction) do
        insert_before_instruction(existing_instructions, [new_instruction], before_instruction)
      end
      def insert_before_instruction(existing_instructions, new_instructions, before_instruction) when is_list(existing_instructions) do
        insert_before_instruction(existing_instructions, new_instructions, before_instruction, [])
      end

      defp insert_before_instruction(existing_instructions = [before_instruction|_], new_instructions, before_instruction, instructions_before_instruction) do
        Enum.reverse(instructions_before_instruction) ++ new_instructions ++ existing_instructions
      end
      defp insert_before_instruction(_existing_instructions = [no_point_of_no_return_instruction|rest], new_instructions, before_instruction, instructions_before_instruction) do
        insert_before_instruction(rest, new_instructions, before_instruction, [no_point_of_no_return_instruction|instructions_before_instruction])
      end
      defp insert_before_instruction(_existing_instructions = [], new_instructions, _before_instruction, instructions_before_instruction) do
        Enum.reverse(instructions_before_instruction) ++ new_instructions
      end


      @doc """
        Inserts an instruction or a list of instructions after the given instruction.
      """
      @spec insert_after_instruction(%Instructions{}|instructions, new_instructions::instruction|instructions, after_instruction::instruction) :: updated_instructions::%Instructions{}|instructions
      def insert_after_instruction(instructions = %Instructions{}, new_instructions, after_instruction) do
        %{instructions|
          up_instructions:   insert_after_instruction(instructions.up_instructions,  new_instructions, after_instruction),
          down_instructions: insert_before_instruction(instructions.down_instructions, new_instructions, after_instruction)
        }
      end
      def insert_after_instruction(existing_instructions, new_instruction, after_instruction) when is_list(existing_instructions) and not is_list(new_instruction) do
        insert_after_instruction(existing_instructions, [new_instruction], after_instruction)
      end
      def insert_after_instruction(existing_instructions, new_instructions, after_instruction) when is_list(existing_instructions) do
        insert_after_instruction(existing_instructions, new_instructions, after_instruction, [])
      end

      defp insert_after_instruction(_existing_instructions = [after_instruction|rest], new_instructions, after_instruction, instructions_before_instruction) do
        Enum.reverse(instructions_before_instruction) ++ [after_instruction|new_instructions] ++ rest
      end
      defp insert_after_instruction(_existing_instructions = [no_point_of_no_return_instruction|rest], new_instructions, after_instruction, instructions_before_instruction) do
        insert_after_instruction(rest, new_instructions, after_instruction, [no_point_of_no_return_instruction|instructions_before_instruction])
      end
      defp insert_after_instruction(_existing_instructions = [], new_instructions, _after_instruction, instructions_before_instruction) do
        Enum.reverse(instructions_before_instruction) ++ new_instructions
      end


      @doc """
        Returns true if the given instruction is an instruction which modifies code by
        loading, unloading or purging it. It returns `true` for the `load_module`, `add_module`
        `delete_module`, `load`, `remove` and `purge` relup instructions.
      """
      @spec modifies_code?(instruction) :: boolean
      def modifies_code?({:load_module, _module}), do: true
      def modifies_code?({:load_module, _module, _dep_mods}), do: true
      def modifies_code?({:load_module, _module, _pre_purge, _post_purge, _dep_mods}), do: true
      def modifies_code?({:add_module,  _module}), do: true
      def modifies_code?({:add_module,  _module, _dep_mods}), do: true
      def modifies_code?({:load,       {_module, _pre_purge, _post_purge}}), do: true
      def modifies_code?({:purge, [_module]}), do: true
      def modifies_code?({:remove, {_module, _pre_purge, _post_purge}}), do: true
      def modifies_code?({:delete_module, _module}), do: true
      def modifies_code?({:delete_module, _module, _dep_mods}), do: true
      def modifies_code?(_), do: false

      @doc """
        Returns true if the given instruction is an instruction which modifies any process
        by either by sending the  `code_change` sys event or by starting or stopping any
        process. It returns `true` for the `code_change`, `start`, `stop` and `update`
        relup instructions.
      """
      @spec modifies_processes?(instruction) :: boolean
      def modifies_processes?({:update, _mod}), do: true
      def modifies_processes?({:update, _mod, :supervisor}), do: true
      def modifies_processes?({:update, _mod, _change_or_dep_mods}), do: true
      def modifies_processes?({:update, _mod, _change, _dep_mods}), do: true
      def modifies_processes?({:update, _mod, _change, _pre_purge, _post_purge, _dep_mods}), do: true
      def modifies_processes?({:update, _mod, Timeout, _change, _pre_purge, _post_purge, _dep_mods}), do: true
      def modifies_processes?({:update, _mod, ModType, Timeout, _change, _pre_purge, _post_purge, _dep_mods}), do: true
      def modifies_processes?({:code_change, [{_mod, _extra}]}), do: true
      def modifies_processes?({:code_change, _mode, [{_mod, _extra}]}), do: true
      def modifies_processes?({:start, [_mod]}), do: true
      def modifies_processes?({:stop, [_mod]}), do: true
      def modifies_processes?(_), do: false

      @doc """
        Returns true if the given instruction is an instruction which modifies an application
        bei either (re-)starting or stopping it or by restarting the emulator. It returns
        `true` for the `add_application`, `remove_application`, `restart_new_emulator`
        and the `restart_emulator`, relup instructions.
      """
      @spec modifies_applications?(instruction) :: boolean
      def modifies_applications?({:add_application, _application}), do: true
      def modifies_applications?({:add_application, _application, _type}), do: true
      def modifies_applications?({:remove_application, _application}), do: true
      def modifies_applications?({:restart_application, _application}), do: true
      def modifies_applications?(:restart_new_emulator), do: true
      def modifies_applications?(:restart_emulator), do: true
      def modifies_applications?(_), do: false


      @doc """
        Ensures that the given module is loaded before the given instruction (if it needs to be loaded).
        If an `%Instructions{}` is given containing also the down instructions, it ensures that the module
        is unloaded after the instruction for the down instructions.
        Use this function only, if the instruction should be used only once in a `Relup.Modification` for
        the up or down instructions. Use the `ensure_module_loaded_before_first_runnable_instructions/2` function
        instead if the `RunnableInstruction` can be used several times in a `Relup.Modification`.
      """
      @spec ensure_module_loaded_before_instruction(%Instructions{}|instructions, instruction::instruction, module::atom) :: updated_instructions::%Instructions{}|instructions
      def ensure_module_loaded_before_instruction(instructions = %Instructions{}, instruction, module) do
        %{instructions|
          up_instructions:   ensure_module_loaded_before_instruction(instructions.up_instructions, instruction, module),
          down_instructions: ensure_module_unloaded_after_instruction(instructions.down_instructions, instruction, module)
        }
      end
      def ensure_module_loaded_before_instruction(up_instructions, instruction, module) when is_list(up_instructions) do
        ensure_module_loaded_before_instruction(up_instructions, instruction, module, _found_instruction = false, [])
      end
      def ensure_module_loaded_before_instruction(instructions, instruction), do: ensure_module_loaded_before_instruction(instructions, instruction, __MODULE__)

      defp ensure_module_loaded_before_instruction(_instructions = [instruction|rest], instruction, module, found_instruction = false, checked_instructions) do
        ensure_module_loaded_before_instruction(rest, instruction, module, _found_instruction = true, [instruction|checked_instructions])
      end
      defp ensure_module_loaded_before_instruction(instructions = [cur_instruction|rest], instruction, module, found_instruction, checked_instructions) do
        found_load_instruction = case cur_instruction do
          {:load_module, ^module} -> true
          {:load_module, ^module, _dep_mods} -> true
          {:load_module, ^module, _pre_purge, _post_purge, _dep_mods} -> true
          {:add_module,  ^module} -> true
          {:add_module,  ^module, _dep_mods} -> true
          {:load,       {^module, _pre_purge, _post_purge}} -> true
          _ -> false
        end
        cond do
          found_load_instruction and found_instruction -> insert_before_instruction(Enum.reverse(checked_instructions) ++ rest, cur_instruction, instruction)
          found_load_instruction and not found_instruction -> Enum.reverse(checked_instructions) ++ instructions # load instruction is already before given instruction
          true -> ensure_module_loaded_before_instruction(rest, instruction, module, found_instruction, [cur_instruction|checked_instructions])
        end
      end
      defp ensure_module_loaded_before_instruction(_instructions = [], _instruction, _module, _found_instruction, checked_instructions) do
        Enum.reverse(checked_instructions)
      end

      @doc """
        Ensures that the given module is loaded before the first occurrence of the runnable instruction (if it needs to be loaded).
        If an `%Instructions{}` is given containing also the down instructions, it ensures that the module
        is unloaded after the last occurrence of the runnable down instruction. Use this function instead of the
        `ensure_module_loaded_before_instruction/3` function if the `RunnableInstruction` can be used several times
        in a `Relup.Modification`.
      """
      @spec ensure_module_loaded_before_first_runnable_instructions(%Instructions{}|instructions, runnable_instruction::{:apply, {module::atom, :run, arguments::[term]}}, module::atom) :: updated_instructions::%Instructions{}|instructions
      def ensure_module_loaded_before_first_runnable_instructions(instructions = %Instructions{}, runnable_instruction, module) do
        %{instructions|
          up_instructions:   ensure_module_loaded_before_first_runnable_instructions(instructions.up_instructions, runnable_instruction, module),
          down_instructions: ensure_module_unloaded_after_last_runnable_instruction(instructions.down_instructions, runnable_instruction, module)
        }
      end
      def ensure_module_loaded_before_first_runnable_instructions(up_instructions, runnable_instruction, module) when is_list(up_instructions) do
        ensure_module_loaded_before_first_runnable_instructions(up_instructions, runnable_instruction, _found_instruction = false, module, [])
      end
      @spec ensure_module_loaded_before_first_runnable_instructions(%Instructions{}|instructions, runnable_instruction::{:apply, {module::atom, :run, arguments::[term]}}) :: updated_instructions::%Instructions{}|instructions
      def ensure_module_loaded_before_first_runnable_instructions(instructions, runnable_instruction = {:apply, {module, :run, _arguments}}) do
        ensure_module_loaded_before_first_runnable_instructions(instructions, runnable_instruction, module)
      end

      defp ensure_module_loaded_before_first_runnable_instructions(instructions = [runnable_instruction|rest], runnable_instruction, _found_instruction = false, module, checked_instructions) do
        ensure_module_loaded_before_first_runnable_instructions(rest, runnable_instruction, _found_instruction = true, module, [runnable_instruction|checked_instructions])
      end
      defp ensure_module_loaded_before_first_runnable_instructions(instructions = [cur_instruction|rest], runnable_instruction = {:apply, {instruction_module, :run, _arguments}}, found_instruction, module, checked_instructions) do
        found_load_instruction = case cur_instruction do
          {:load_module, ^module} -> true
          {:load_module, ^module, _dep_mods} -> true
          {:load_module, ^module, _pre_purge, _post_purge, _dep_mods} -> true
          {:add_module,  ^module} -> true
          {:add_module,  ^module, _dep_mods} -> true
          {:load,       {^module, _pre_purge, _post_purge}} -> true
          _ -> false
        end
        cond do
          found_load_instruction and found_instruction ->
            first_runnable_instruction = first_runnable_instruction(Enum.reverse(checked_instructions) ++ instructions ++ [runnable_instruction], instruction_module)
            insert_before_instruction(Enum.reverse(checked_instructions) ++ rest, cur_instruction, first_runnable_instruction)
          found_load_instruction and not found_instruction ->
            Enum.reverse(checked_instructions) ++ instructions # load instruction is already before given runnable instruction
          true ->
            ensure_module_loaded_before_first_runnable_instructions(rest, runnable_instruction, found_instruction, module, [cur_instruction|checked_instructions])
        end
      end
      defp ensure_module_loaded_before_first_runnable_instructions(_instructions = [], _runnable_instruction, _found_instruction, module, checked_instructions) do
        Enum.reverse(checked_instructions)
      end

      @doc """
        Returns the first occurence of a `RunnableInstruction` implemented by the given module.
      """
      @spec first_runnable_instruction(instructions::instructions, module::atom) :: runnable_instruction::{:apply, {module::atom, :run, arguments::[term]}} | :not_found
      def first_runnable_instruction(_instructions = [], _module), do: :not_found
      def first_runnable_instruction(_instructions = [runnable_instruction = {:apply, {module, :run, _arguments}}|_], module) do
        runnable_instruction
      end
      def first_runnable_instruction(_instructions = [_|rest], module) do
        first_runnable_instruction(rest, module)
      end

      @doc """
        Ensures that the given module is (un)loaded after the given instruction (if it needs to be (un)loaded).
        If an `%Instructions{}` is given containing also the down instructions, it ensures that the module
        is (un)loaded before the instruction for the down instructions.
        Use this function only, if the instruction should be used only once in a `Relup.Modification` for
        the up or down instructions. Use the `ensure_module_unloaded_after_last_runnable_instruction/2` function
        instead if the `RunnableInstruction` can be used several times in a `Relup.Modification`.
      """
      @spec ensure_module_unloaded_after_instruction(%Instructions{}|instructions, instruction::instruction, module::atom) :: updated_instructions::%Instructions{}|instructions
      def ensure_module_unloaded_after_instruction(instructions = %Instructions{}, instruction, module) do
        %{instructions|
          up_instructions:   ensure_module_unloaded_after_instruction(instructions.up_instructions, instruction, module),
          down_instructions: ensure_module_loaded_before_instruction(instructions.down_instructions, instruction, module)
        }
      end
      def ensure_module_unloaded_after_instruction(up_instructions, instruction, module) when is_list(up_instructions) do
        ensure_module_unloaded_after_instruction(up_instructions, instruction, module, [])
      end
      def ensure_module_unloaded_after_instruction(instructions, instruction), do: ensure_module_unloaded_after_instruction(instructions, instruction, __MODULE__)

      defp ensure_module_unloaded_after_instruction(instructions = [instruction|rest], instruction, module, checked_instructions) do
        Enum.reverse(checked_instructions) ++ instructions # don't need to check instructions after instruction
      end
      defp ensure_module_unloaded_after_instruction(_instructions = [cur_instruction|rest], instruction, module, checked_instructions) do
        found_unload_instruction = case cur_instruction do
          found_unload_instruction = {:load_module, ^module} -> insert_after_instruction(Enum.reverse(checked_instructions) ++ rest, cur_instruction, instruction)
          {:load_module, ^module, _dep_mods} -> true
          {:load_module, ^module, _pre_purge, _post_purge, _dep_mods} -> true
          {:add_module,  ^module} -> true
          {:add_module,  ^module, _dep_mods} -> true
          {:load,       {^module, _pre_purge, _post_purge}} -> true
          {:remove, {^module, _pre_purge, _post_purge}} -> true
          {:delete_module, ^module} -> true
          {:delete_module, ^module, _dep_mods} -> true
          {:purge, [^module]} -> true
          _ -> false
        end
        if found_unload_instruction do
          insert_after_instruction(Enum.reverse(checked_instructions) ++ rest, cur_instruction, instruction)
          |> ensure_module_unloaded_after_instruction(instruction, module, []) # continue finding unload instructions before
        else
          ensure_module_unloaded_after_instruction(rest, instruction, module, [cur_instruction|checked_instructions])
        end
      end
      defp ensure_module_unloaded_after_instruction(_instructions = [], _instruction, _module, checked_instructions) do
        Enum.reverse(checked_instructions)
      end

      @doc """
        Ensures that the given module is (un)loaded after the last occurrenct of the given runnable instruction (if it needs to be (un)loaded).
        If an `%Instructions{}` is given containing also the down instructions, it ensures that the module
        is loaded before the first occurrence of the runnable instruction for the down instructions.
        Use this function instead of the `ensure_module_unloaded_after_instruction/3` function if the `RunnableInstruction`
        can be used several times  in a `Relup.Modification`.
      """
      @spec ensure_module_unloaded_after_last_runnable_instruction(%Instructions{}|instructions, runnable_instruction::{:apply, {module::atom, :run, arguments::[term]}}, module::atom) :: updated_instructions::%Instructions{}|instructions
      def ensure_module_unloaded_after_last_runnable_instruction(instructions = %Instructions{}, runnable_instruction, module) do
        %{instructions|
          up_instructions:   ensure_module_unloaded_after_last_runnable_instruction(instructions.up_instructions, runnable_instruction, module),
          down_instructions: ensure_module_loaded_before_first_runnable_instructions(instructions.down_instructions, runnable_instruction, module)
        }
      end
      def ensure_module_unloaded_after_last_runnable_instruction(up_instructions, runnable_instruction, module) when is_list(up_instructions) do
        ensure_module_unloaded_after_last_runnable_instruction(up_instructions, runnable_instruction, module, [])
      end
      def ensure_module_unloaded_after_last_runnable_instruction(instructions, runnable_instruction = {:apply, {module, :run, _arguments}}) do
        ensure_module_unloaded_after_last_runnable_instruction(instructions, runnable_instruction, module)
      end

      defp ensure_module_unloaded_after_last_runnable_instruction(instructions = [runnable_instruction|rest], runnable_instruction, module, checked_instructions) do
        Enum.reverse(checked_instructions) ++ instructions # don't need to check instructions after instruction
      end
      defp ensure_module_unloaded_after_last_runnable_instruction(instructions = [cur_instruction|rest], runnable_instruction = {:apply, {instruction_module, :run, _arguments}}, module, checked_instructions) do
        found_unload_instruction = case cur_instruction do
          {:load_module, ^module} -> true
          {:load_module, ^module, _dep_mods} -> true
          {:load_module, ^module, _pre_purge, _post_purge, _dep_mods} -> true
          {:add_module,  ^module} -> true
          {:add_module,  ^module, _dep_mods} -> true
          {:load,       {^module, _pre_purge, _post_purge}} -> true
          {:remove, {^module, _pre_purge, _post_purge}} -> true
          {:delete_module, ^module} -> true
          {:delete_module, ^module, _dep_mods} -> true
          {:purge, [^module]} -> true
          _ -> false
        end
        if found_unload_instruction do
          last_runnable_instruction = first_runnable_instruction(Enum.reverse(Enum.reverse(checked_instructions) ++ instructions ++ [runnable_instruction]), instruction_module)
          insert_after_instruction(Enum.reverse(checked_instructions) ++ rest, cur_instruction, last_runnable_instruction)
          |> ensure_module_unloaded_after_last_runnable_instruction(runnable_instruction, module, []) # continue finding unload instructions before
        else
          ensure_module_unloaded_after_last_runnable_instruction(rest, runnable_instruction, module, [cur_instruction|checked_instructions])
        end
      end
      defp ensure_module_unloaded_after_last_runnable_instruction(_instructions = [], _runnable_instruction, _module, checked_instructions) do
        Enum.reverse(checked_instructions)
      end


    end
  end

end