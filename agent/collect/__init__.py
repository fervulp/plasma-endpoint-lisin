"""The few places that touch the live system directly.

Everything the pipeline can collect goes through an input; what is left here is
answering an interactive question from the interface (a WHOIS lookup), the EDR
breakdown of one process and the resource metrics of the application itself.
"""
