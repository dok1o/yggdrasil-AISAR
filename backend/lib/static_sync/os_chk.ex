defmodule OSChkSync do
  def os_rules() do
    case os_type() do
      :linux_os -> :linux_rules
      :other_unix_os -> :mac_rules
      t when t in [:windows_os, :other_os] -> :non_unix_rules
    end
  end
  defp os_type() do
    case :os.type() do
      {:unix, :linux} -> :linux_os
      {:unix, _any_unix} -> :other_unix_os
      {win, _any_win} when win in [:win32, :win64] -> :windows_os
      _any_os -> :other_os
    end
  end
end